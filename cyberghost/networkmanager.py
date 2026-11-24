"""NetworkManager WireGuard tunnel lifecycle (unprivileged, Polkit-authorized)."""

import configparser
import ipaddress
import json
import os
import re
import subprocess
import time
import uuid

from .constants import (
    INTERFACE,
    NATIVE_CONNECT_BUDGET_SECONDS,
    NM_CONNECTION_NAME,
    NM_DNS_PRIORITY,
    NM_REQUIRED_PERMISSIONS,
    NM_UUID_NAMESPACE,
    NMCLI_NOT_FOUND,
)
from .credentials import load_account, user_config_path, validate_user_config_path
from .server_selection import exchange_wireguard_key, select_native_candidates
from .system import OperationCancelled, clean_command_error, invoking_user, run_bounded, system_binary
from .validation import (
    validate_dns_servers,
    validate_endpoint_host,
    validate_ip,
    validate_port,
    validate_wireguard_key,
)
from .wireguard import generate_wireguard_keys


def _interface_state(ip_binary):
    """Return True/False/None for present/absent/unknown interface state."""
    try:
        result = run_bounded([ip_binary, "link", "show", INTERFACE], timeout=5, max_output_bytes=8 * 1024)
    except (OSError, subprocess.TimeoutExpired, RuntimeError):
        return None
    if result.returncode == 0:
        return INTERFACE in (result.stdout or "")
    detail = f"{result.stdout or ''}\n{result.stderr or ''}"
    if result.returncode == 1 and re.search(r"does not exist|cannot find|not found|no such device", detail, re.I):
        return False
    return None


class LegacyTunnelError(RuntimeError):
    """A tunnel created by the pre-1.7 root helper is still up."""

    code = "legacy_tunnel"


LEGACY_TUNNEL_MESSAGE = (
    "A tunnel from the previous CyberGhost root helper is still active. "
    "Disconnect it before using the NetworkManager connection."
)


def connection_uuid():
    """Stable per-user profile id, so every action addresses only our connection."""
    return str(uuid.uuid5(NM_UUID_NAMESPACE, f"miguel.cyberghost:{os.getuid()}"))


def nmcli(args, timeout=15, input_data=None):
    # nmcli messages are parsed only for diagnostics; keep them in English.
    env = dict(os.environ, LC_ALL="C")
    return run_bounded(
        [system_binary("nmcli"), *args],
        timeout=timeout,
        input_data=input_data,
        max_output_bytes=32 * 1024,
        env=env,
    )


def nm_available():
    """NetworkManager (Omarchy's network stack) must be installed and running."""
    try:
        result = nmcli(["-t", "-f", "RUNNING", "general"], timeout=5)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired, RuntimeError):
        return False
    return result.returncode == 0 and (result.stdout or "").strip() == "running"


def nm_permission():
    """Return yes/auth/no for the least-permitted action this plugin needs."""
    try:
        result = nmcli(["-t", "general", "permissions"], timeout=5)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired, RuntimeError):
        return ""
    if result.returncode != 0:
        return ""
    values = {}
    for line in (result.stdout or "").splitlines():
        name, _, value = line.partition(":")
        values[name.strip()] = value.strip()
    needed = [values.get(f"org.freedesktop.NetworkManager.{name}", "") for name in NM_REQUIRED_PERMISSIONS]
    for level in ("", "no", "auth"):
        if level in needed:
            return level
    return "yes"


def nm_active_state():
    """Return our connection's active state ("" when inactive); raise when NM is unreadable."""
    result = nmcli(["-t", "-f", "UUID,STATE", "connection", "show", "--active"], timeout=5)
    if result.returncode != 0:
        raise RuntimeError(clean_command_error(result.stderr or result.stdout, "NetworkManager state is unavailable"))
    target = connection_uuid()
    for line in (result.stdout or "").splitlines():
        found_uuid, _, state = line.partition(":")
        if found_uuid == target:
            return state.strip()[:32]
    return ""


def nm_profile_exists():
    result = nmcli(["-t", "-f", "UUID", "connection", "show"], timeout=5)
    if result.returncode != 0:
        raise RuntimeError(
            clean_command_error(result.stderr or result.stdout, "NetworkManager profiles are unavailable")
        )
    return connection_uuid() in (result.stdout or "").split()


def nm_state_or_none():
    """Our connection's state, or None when NetworkManager cannot be queried."""
    try:
        return nm_active_state()
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired, RuntimeError):
        return None


def legacy_tunnel_active(ip_binary):
    """The interface exists but is not our NetworkManager connection.

    With NetworkManager unreachable our in-memory profile cannot be active, so
    any cyberghost interface must come from the pre-1.7 helper.
    """
    return _interface_state(ip_binary) is True and not nm_state_or_none()


def nm_remove_profile(ip_binary):
    """Deactivate and delete our profile; return only verified residual problems."""
    target = connection_uuid()
    problems = []
    for verb, timeout in (("down", 20), ("delete", 10)):
        try:
            result = nmcli(["connection", verb, "uuid", target], timeout=timeout)
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as exc:
            problems.append(f"nmcli connection {verb} failed: {clean_command_error(exc)}")
            continue
        # Exit 10 means the profile or activation does not exist.
        if result.returncode not in (0, NMCLI_NOT_FOUND):
            problems.append(clean_command_error(result.stderr or result.stdout, f"nmcli connection {verb} failed"))
    try:
        if nm_profile_exists():
            problems.append("the CyberGhost NetworkManager profile is still present")
    except RuntimeError as exc:
        problems.append(str(exc))
    interface_state = _interface_state(ip_binary)
    if interface_state is None:
        problems.append("WireGuard interface state could not be verified")
    elif interface_state:
        problems.append(f"interface {INTERFACE} is still present")
    return problems


def nm_profile_args(peer_ip, server_key, server_host, server_port, dns_servers, allowed_ips=("0.0.0.0/0", "::/0")):
    """Build `nmcli connection add` arguments. Secrets are never part of argv."""
    valid_peer_ip = validate_ip(peer_ip)
    if ":" in valid_peer_ip:
        raise RuntimeError("CyberGhost returned an IPv6 tunnel address; only IPv4 tunnel addresses are supported")
    valid_server_key = validate_wireguard_key(server_key)
    valid_host = validate_endpoint_host(server_host)
    endpoint_host = f"[{valid_host}]" if ":" in valid_host else valid_host
    valid_port = validate_port(server_port)
    dns = [item.strip() for item in validate_dns_servers(dns_servers, require_nonempty=True).split(",")]
    dns4 = [item for item in dns if ":" not in item]
    dns6 = [item for item in dns if ":" in item]
    routes = [str(ipaddress.ip_network(item)) for item in allowed_ips]

    args = [
        "connection",
        "add",
        # In-memory only: the profile and its per-session key vanish on NM restart.
        "save",
        "no",
        "type",
        "wireguard",
        "con-name",
        NM_CONNECTION_NAME,
        "ifname",
        INTERFACE,
        "connection.uuid",
        connection_uuid(),
        "connection.autoconnect",
        "no",
        "ipv4.method",
        "manual",
        "ipv4.addresses",
        f"{valid_peer_ip}/32",
        "ipv4.ignore-auto-dns",
        "yes",
        # Link-local IPv6 lets NM install the ::/0 tunnel route, so IPv6 cannot
        # bypass the tunnel even though CyberGhost assigns no IPv6 address.
        "ipv6.method",
        "link-local",
        "ipv6.ignore-auto-dns",
        "yes",
        "wireguard.peers",
        f"{valid_server_key} allowed-ips={';'.join(routes)} endpoint={endpoint_host}:{valid_port} "
        f"persistent-keepalive=25",
    ]
    user = invoking_user().pw_name
    if re.fullmatch(r"[A-Za-z0-9._][A-Za-z0-9._-]*", user):
        args += ["connection.permissions", f"user:{user}"]
    # `~.` plus a negative priority makes this link the exclusive DNS route in
    # systemd-resolved. An Omarchy global DNS choice (`omarchy dns`) still wins;
    # those public resolvers are then reached through the tunnel.
    for family, servers in (("ipv4", dns4), ("ipv6", dns6)):
        if servers:
            args += [f"{family}.dns", ",".join(servers), f"{family}.dns-search", "~."]
            args += [f"{family}.dns-priority", str(NM_DNS_PRIORITY)]
    return args


def nm_activate(profile_args, private_key, ip_binary, deadline):
    """Add, key and activate the profile; roll back on every failure."""
    target = connection_uuid()
    key = validate_wireguard_key(private_key)
    try:
        added = nmcli(profile_args, timeout=15)
        if added.returncode != 0:
            raise RuntimeError(clean_command_error(added.stderr or added.stdout, "Could not create the VPN connection"))
        # Omarchy's network panel uses the same rule: secrets go through the
        # scriptable editor on stdin, because argv is world-readable in /proc.
        keyed = nmcli(
            ["connection", "edit", "uuid", target],
            timeout=15,
            input_data=f"set wireguard.private-key {key}\nsave temporary\nquit\n",
        )
        if keyed.returncode != 0:
            raise RuntimeError("Could not store the WireGuard key in NetworkManager")
        remaining = int(deadline - time.monotonic())
        if remaining <= 2:
            raise RuntimeError("WireGuard connection attempt timed out before activation")
        wait = min(45, remaining - 1)
        activated = nmcli(["--wait", str(wait), "connection", "up", "uuid", target], timeout=wait + 5)
        if activated.returncode != 0:
            raise RuntimeError(
                "NetworkManager could not activate the VPN: "
                + clean_command_error(activated.stderr or activated.stdout, "unknown error")
            )
        if nm_active_state() != "activated" or _interface_state(ip_binary) is not True:
            raise RuntimeError("NetworkManager reported success but the CyberGhost interface is not active")
    except (OperationCancelled, OSError, subprocess.TimeoutExpired, RuntimeError) as exc:
        problems = nm_remove_profile(ip_binary)
        message = clean_command_error(exc, "WireGuard activation failed")
        if problems:
            message += f"; rollback incomplete: {'; '.join(problems)}"
        raise RuntimeError(message) from exc


def connect(country_code="PT", server_type="traffic", city=None, config_path=None, server=None):
    """Roll back cancellation through the entire connection publication boundary."""
    replacement = {"started": False}
    try:
        return _connect(country_code, server_type, city, config_path, server, replacement)
    except OperationCancelled as exc:
        if replacement["started"]:
            problems = nm_remove_profile(system_binary("ip"))
            if problems:
                raise RuntimeError("Operation cancelled; rollback incomplete: " + "; ".join(problems)) from exc
        raise


def _connect(country_code, server_type, city, config_path, server, replacement):
    """Negotiate a CyberGhost peer and activate it as an in-memory NM connection."""
    if os.geteuid() == 0:
        raise RuntimeError("Run CyberGhost as your desktop user; NetworkManager authorizes the connection.")
    deadline = time.monotonic() + NATIVE_CONNECT_BUDGET_SECONDS
    try:
        ip_binary = system_binary("ip")
    except (FileNotFoundError, RuntimeError) as exc:
        raise RuntimeError("iproute2 is required to verify the VPN interface") from exc
    if not nm_available():
        raise RuntimeError("NetworkManager is not running. Omarchy's network stack is required.")
    if legacy_tunnel_active(ip_binary):
        raise LegacyTunnelError(LEGACY_TUNNEL_MESSAGE)

    account = load_account(config_path)
    token, secret = account["token"], account["secret"]
    priv_key, pub_key = generate_wireguard_keys()
    cc, candidates = select_native_candidates(country_code, server_type, city, server, session=account)
    addkey_data, connected_host = exchange_wireguard_key(candidates, pub_key, token, secret, cc, deadline)

    # A missing field gets the documented compatibility defaults. An explicit
    # empty field is invalid: never activate without a VPN DNS configuration.
    raw_dns = addkey_data["dns_servers"] if "dns_servers" in addkey_data else ["10.0.0.243", "10.0.0.242", "1.1.1.1"]
    dns_servers = validate_dns_servers(raw_dns, require_nonempty=True)
    server_ip = validate_endpoint_host(addkey_data.get("server_ip") or connected_host)
    server_port = validate_port(addkey_data.get("server_port", 1337))
    peer_ip = validate_ip(addkey_data.get("peer_ip", ""))
    server_key = validate_wireguard_key(addkey_data.get("server_key", ""))
    profile_args = nm_profile_args(peer_ip, server_key, server_ip, server_port, dns_servers)

    # Before this boundary cancellation leaves any existing session untouched.
    replacement["started"] = True
    # Replace a previous session of our own profile; nothing else is touched.
    problems = nm_remove_profile(ip_binary)
    if problems:
        raise RuntimeError("Cannot replace the existing CyberGhost connection: " + "; ".join(problems))
    nm_activate(profile_args, priv_key, ip_binary, deadline)

    print("VPN connection established.")
    print(f"Connected to {cc} via {connected_host} (IP: {server_ip})")
    return {
        "backend": "networkmanager",
        "country": cc,
        "server": connected_host,
        "server_ip": server_ip,
        "protocol": "wireguard",
        "server_type": server_type,
    }


def disconnect():
    try:
        ip_binary = system_binary("ip")
    except (FileNotFoundError, RuntimeError) as exc:
        raise RuntimeError("iproute2 is required to verify the VPN interface") from exc
    if legacy_tunnel_active(ip_binary):
        raise LegacyTunnelError(LEGACY_TUNNEL_MESSAGE)
    state = nm_state_or_none()
    if state is None and _interface_state(ip_binary) is False:
        # Nothing to remove, and NetworkManager is not there to ask.
        print("No VPN connections found.")
        return {"backend": "networkmanager", "connected": False}
    was_up = bool(state)
    problems = nm_remove_profile(ip_binary)
    if problems:
        raise RuntimeError("Could not verify VPN cleanup: " + "; ".join(problems))
    print("VPN connection terminated." if was_up else "No VPN connections found.")
    return {"backend": "networkmanager", "connected": False}


def interface_counters():
    """Read world-readable kernel counters; handshake age needs CAP_NET_ADMIN."""
    counters = {}
    for name in ("rx_bytes", "tx_bytes"):
        try:
            with open(f"/sys/class/net/{INTERFACE}/statistics/{name}", encoding="ascii") as stream:
                value = stream.read(32).strip()
        except OSError:
            continue
        if value.isdigit():
            counters[name] = int(value)
    return counters


def format_bytes(count):
    value = float(count)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.2f} {unit}"
        value /= 1024
    return f"{count} B"


def nm_endpoint():
    try:
        result = nmcli(["-g", "wireguard.peers", "connection", "show", "uuid", connection_uuid()], timeout=5)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired, RuntimeError):
        return ""
    match = re.search(r"endpoint=(\S+)", result.stdout or "") if result.returncode == 0 else None
    # `nmcli -g` escapes the separator characters inside values.
    return match.group(1).replace("\\:", ":")[:64] if match else ""


def status(as_json=False):
    state = nm_state_or_none() or ""
    link = _interface_state(system_binary("ip"))
    if state:
        backend = "networkmanager"
    elif link is True:
        backend = "legacy"
    else:
        backend = None
    connected = state == "activated" or backend == "legacy"
    result = {
        "connected": connected,
        "backend": backend,
        "state": state,
        "interface": INTERFACE if backend else None,
    }
    if state == "activated":
        counters = interface_counters()
        result.update(counters)
        if "rx_bytes" in counters and "tx_bytes" in counters:
            result["transfer"] = (
                f"{format_bytes(counters['rx_bytes'])} received, {format_bytes(counters['tx_bytes'])} sent"
            )
        endpoint = nm_endpoint()
        if endpoint:
            result["endpoint"] = endpoint

    if as_json:
        print(json.dumps(result))
    elif backend == "legacy":
        print("VPN connection found (previous root helper).")
    elif connected:
        print("VPN connection found.")
        print(f"Interface: {INTERFACE}")
        for key in ("endpoint", "transfer"):
            if key in result:
                print(f"  {key}: {result[key]}")
    elif state:
        print(f"VPN connection {state}.")
    else:
        print("No VPN connections found.")


def logout():
    """Forget this plugin's device credentials, disconnecting our tunnel first.

    Only ~/.cyberghost/native.ini is removed. The vendor CLI's config.ini is
    not ours to delete; the result reports when it still provides an account.
    """
    if os.geteuid() == 0:
        raise RuntimeError("Run CyberGhost as your desktop user.")
    disconnected = False
    if nm_available():
        ip_binary = system_binary("ip")
        if legacy_tunnel_active(ip_binary):
            raise LegacyTunnelError(LEGACY_TUNNEL_MESSAGE)
        if nm_active_state() or nm_profile_exists():
            disconnected = disconnect()["connected"] is False
    path = validate_user_config_path(user_config_path())
    try:
        # unlink removes a symlink itself, never its target.
        os.unlink(path)
        removed = True
    except FileNotFoundError:
        removed = False
    except OSError as exc:
        raise RuntimeError(f"Could not remove {path}: {exc}") from exc
    try:
        remaining = load_account(None)["source"]
    except (OSError, RuntimeError, configparser.Error):
        remaining = ""
    print("Logged out." if removed else "No plugin account was linked.")
    return {"logged_out": removed, "disconnected": disconnected, "connected": False, "remaining_source": remaining}

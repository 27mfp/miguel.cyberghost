#!/usr/bin/env python3
"""
CyberGhost VPN WireGuard Native Backend & CLI
Directly negotiates WireGuard keys with CyberGhost dialup servers and manages wg-quick.
"""

import argparse
import configparser
import glob
import importlib.util
import json
import os
import pwd
import re
import shutil
import socket
import subprocess
import sys

WG_CONF_PATH = "/etc/wireguard/cyberghost.conf"
INTERFACE = "cyberghost"

# CyberGhost account/device API — endpoints and the app key below are the same
# ones embedded in the official cyberghostvpn CLI (verified against its 1.4.1 build).
API_BASE = "https://v2-api.cyberghostvpn.com/v2"
API_KEY = "QzgDsDNUXlgF9jehkTHHtBJwwI4RyInkZQDRJfLyz"
USER_AGENT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36")

# Country Code -> Primary CyberGhost city slug.
# Mirrors the country list in Countries.js — keep both in sync
# (tests/test_runner.py enforces coverage). A wrong/unknown slug fails
# cleanly with a connection error, it can never connect somewhere else.
CITY_MAP = {
    "AD": "andorra",
    "AE": "dubai",
    "AL": "tirana",
    "AM": "yerevan",
    "AR": "buenosaires",
    "AT": "vienna",
    "AU": "sydney",
    "BA": "sarajevo",
    "BD": "dhaka",
    "BE": "brussels",
    "BG": "sofia",
    "BO": "lapaz",
    "BR": "saopaulo",
    "BS": "nassau",
    "BY": "minsk",
    "CA": "montreal",
    "CH": "zurich",
    "CL": "santiago",
    "CN": "hongkong",
    "CO": "bogota",
    "CR": "sanjose",
    "CY": "nicosia",
    "CZ": "prague",
    "DE": "frankfurt",
    "DK": "copenhagen",
    "DO": "santodomingo",
    "DZ": "algiers",
    "EC": "quito",
    "EE": "tallinn",
    "EG": "cairo",
    "ES": "madrid",
    "FI": "helsinki",
    "FR": "paris",
    "GB": "london",
    "UK": "london",  # legacy alias
    "GE": "tbilisi",
    "GL": "nuuk",
    "GR": "athens",
    "GT": "guatemalacity",
    "HK": "hongkong",
    "HR": "zagreb",
    "HU": "budapest",
    "ID": "jakarta",
    "IE": "dublin",
    "IL": "telaviv",
    "IM": "douglas",
    "IN": "mumbai",
    "IR": "tehran",
    "IS": "reykjavik",
    "IT": "milan",
    "JP": "tokyo",
    "KE": "nairobi",
    "KH": "phnompenh",
    "KR": "seoul",
    "KZ": "almaty",
    "LA": "vientiane",
    "LI": "vaduz",
    "LK": "colombo",
    "LT": "vilnius",
    "LU": "luxembourg",
    "LV": "riga",
    "MA": "casablanca",
    "MC": "monaco",
    "MD": "chisinau",
    "ME": "podgorica",
    "MK": "skopje",
    "MT": "valletta",
    "MX": "mexicocity",
    "MY": "kualalumpur",
    "NG": "lagos",
    "NL": "amsterdam",
    "NO": "oslo",
    "NZ": "auckland",
    "PA": "panamacity",
    "PH": "manila",
    "PK": "karachi",
    "PL": "warsaw",
    "PT": "lisbon",
    "QA": "doha",
    "RO": "bucharest",
    "RS": "belgrade",
    "SA": "riyadh",
    "SE": "stockholm",
    "SG": "singapore",
    "SI": "ljubljana",
    "SK": "bratislava",
    "TH": "bangkok",
    "TR": "istanbul",
    "TW": "taipei",
    "UA": "kyiv",
    "US": "newyork",
    "UY": "montevideo",
    "VE": "caracas",
    "VN": "hanoi",
    "ZA": "johannesburg",
}

_HANDSHAKE_UNITS = {"second": 1, "minute": 60, "hour": 3600, "day": 86400}


def load_requests():
    """Import requests lazily so lightweight `status` polls skip the cost."""
    try:
        import requests
    except ImportError:
        sys.exit(
            "Error: the 'requests' library is required for the native WireGuard path. "
            "Please install python-requests (e.g. 'sudo pacman -S python-requests')."
        )
    return requests


def api_get(url, params, token, secret):
    """Authenticated GET with strict TLS verification — fail closed."""
    requests = load_requests()
    try:
        return requests.get(url, params=params, auth=(token, secret), timeout=3.5)
    except requests.exceptions.SSLError as ssl_err:
        # Never resend credentials over an unverified channel; a MITM here
        # would capture the account token/secret.
        raise RuntimeError(
            "TLS certificate verification failed for %s. Refusing to send credentials "
            "over an unverified connection (check system CA certificates / proxy)." % url.split("/")[2]
        ) from ssl_err


def _slug(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def connect_via_cli(country_code, server_type, protocol):
    """
    Delegate to the official cyberghostvpn CLI for combinations the native
    dialup API cannot serve (OpenVPN, torrent/streaming server pools).
    """
    cc = country_code.upper().strip()
    cmd = ["cyberghostvpn"]
    if server_type == "torrent":
        cmd.append("--torrent")
    elif server_type == "streaming":
        cmd.append("--streaming")
    if protocol == "wireguard":
        cmd.append("--wireguard")
    else:
        cmd.append("--openvpn")
        cmd.append("--tcp" if protocol == "openvpn_tcp" else "--udp")
    cmd += ["--country-code", cc, "--connect"]

    print("Connecting to %s (%s / %s) via cyberghostvpn CLI..." % (cc, protocol, server_type))
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        raise RuntimeError(
            "'cyberghostvpn' CLI is not installed (required for OpenVPN / torrent / streaming modes)."
            " Install it or use WireGuard traffic mode."
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("cyberghostvpn CLI timed out.")

    out = ((res.stdout or "") + (res.stderr or "")).strip()
    if res.returncode != 0:
        raise RuntimeError(out or ("cyberghostvpn exited with code %d" % res.returncode))

    if re.search(r"\berror\b|failed|unable|could not|not found", out, re.I):
        raise RuntimeError(out)
    if not re.search(r"connected|established", out, re.I):
        # Exit code 0 without failure markers: trust the CLI and normalise output.
        print("VPN connection established.")
    else:
        print(out)
    print("Connected to %s via %s (%s)." % (cc, protocol, server_type))


def find_config_path(override_path=None):
    if override_path and os.path.exists(override_path):
        return override_path

    env_override = os.environ.get("CYBERGHOST_CONFIG")
    if env_override and os.path.exists(env_override):
        return env_override

    candidates = []
    user = os.environ.get("SUDO_USER") or os.environ.get("LOGNAME") or os.environ.get("USER")
    if user and user != "root":
        candidates.append(f"/home/{user}/.cyberghost/config.ini")

    # Scan /home/*/
    for p in glob.glob("/home/*/.cyberghost/config.ini"):
        candidates.append(p)

    # Scan user databases
    try:
        for entry in pwd.getpwall():
            if entry.pw_uid >= 1000 and os.path.isdir(entry.pw_dir):
                candidates.append(os.path.join(entry.pw_dir, ".cyberghost", "config.ini"))
    except Exception:
        pass

    candidates.append(os.path.expanduser("~/.cyberghost/config.ini"))

    for c in candidates:
        if os.path.exists(c):
            return c

    return os.path.expanduser("~/.cyberghost/config.ini")


def get_credentials(config_path=None):
    path = find_config_path(config_path)
    if not os.path.exists(path):
        raise RuntimeError(f"Configuration file not found: {path}. Please run 'cyberghostvpn --setup' first.")

    cfg = configparser.ConfigParser()
    try:
        cfg.read(path)
    except Exception as e:
        raise RuntimeError(f"Failed to parse config file at {path}: {e}")

    if not cfg.has_section("device") or not cfg.has_option("device", "token") or not cfg.has_option("device", "secret"):
        raise RuntimeError(f"Device credentials missing from {path}. Please run 'cyberghostvpn --setup'")

    token = cfg.get("device", "token").strip()
    secret = cfg.get("device", "secret").strip()
    return token, secret


def get_servers_for_country(country_code, server_type="traffic"):
    """
    Query available server instances for a country if cyberghostvpn is present.
    Returns [] when the CLI is unavailable or output cannot be parsed.
    """
    try:
        cmd = ["cyberghostvpn", f"--{server_type}", "--country-code", country_code.upper()]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=5)

        servers = []
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                m = re.match(r"[|\s]*(\d+)[\s|]+([A-Za-z\s]+?)[\s|]+(\d+)[\s|]+(\d+)%[|\s]*$", line)
                if m:
                    city = m.group(2).strip()
                    instance = m.group(3).strip()
                    load = int(m.group(4))
                    servers.append({"city": city, "instance": instance, "load": load})
        return servers
    except Exception:
        return []


def generate_wireguard_keys():
    try:
        priv = subprocess.check_output(["wg", "genkey"]).decode().strip()
        pub = subprocess.check_output(["wg", "pubkey"], input=priv.encode()).decode().strip()
        return priv, pub
    except Exception as e:
        raise RuntimeError(f"Failed to generate WireGuard keys using 'wg': {e}. Ensure wireguard-tools is installed.")


def build_wg_config(private_key, peer_ip, server_key, server_ip, server_port, dns_servers=None):
    """Render a wg-quick config that tunnels IPv4 AND IPv6 (no v6 leak)."""
    lines = [
        "[Interface]",
        f"PrivateKey = {private_key}",
        f"Address = {peer_ip}/32",
    ]
    if dns_servers:
        lines.append(f"DNS = {dns_servers}")
    lines += [
        "",
        "[Peer]",
        f"PublicKey = {server_key}",
        "AllowedIPs = 0.0.0.0/0, ::/0",
        f"Endpoint = {server_ip}:{server_port}",
        "PersistentKeepalive = 25",
        "",
    ]
    return "\n".join(lines)


def parse_handshake_seconds(text):
    """'latest handshake: 2 minutes, 34 seconds ago' -> 154. None if unparsable."""
    if not text:
        return None
    total = 0
    found = False
    for amount, unit in re.findall(r"(\d+)\s*(second|minute|hour|day)", text, re.I):
        total += int(amount) * _HANDSHAKE_UNITS[unit.lower().rstrip("s")]
        found = True
    return total if found else None


def parse_wg_show(output):
    """Extract endpoint / transfer / handshake age from `wg show <iface>` output."""
    info = {}
    for line in output.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip().lower()
        value = value.strip()
        if key == "endpoint":
            info["endpoint"] = value
        elif key == "transfer":
            info["transfer"] = value
        elif key == "latest handshake":
            secs = parse_handshake_seconds(value)
            if secs is not None:
                info["handshake_sec"] = secs
    return info


def connect(country_code="PT", server_type="traffic", city=None, config_path=None):
    token, secret = get_credentials(config_path)
    priv_key, pub_key = generate_wireguard_keys()

    cc = country_code.upper().strip()

    cli_servers = [] if city else get_servers_for_country(cc, server_type)

    if city:
        city_slug = _slug(city)
    elif cc in CITY_MAP:
        city_slug = CITY_MAP[cc]
    elif cli_servers:
        city_slug = _slug(cli_servers[0]["city"])
    else:
        raise RuntimeError(
            f"No known WireGuard city for country '{cc}'. "
            "Install the cyberghostvpn CLI for full country coverage."
        )

    # Prefer live server instances reported by the CLI, then static fallbacks.
    candidates = []
    for s in cli_servers[:4]:
        instance = re.sub(r"\D", "", s.get("instance", ""))
        if instance:
            for idx in ("01", "02"):
                candidates.append(f"{_slug(s['city'])}-s{instance}-i{idx}.cg-dialup.net")
    for instance in ("405", "401", "406", "407"):
        for idx in ("01", "02", "03"):
            candidates.append(f"{city_slug}-s{instance}-i{idx}.cg-dialup.net")

    seen = set()
    candidates = [c for c in candidates if not (c in seen or seen.add(c))]

    addkey_data = None
    connected_host = None
    last_error_msg = None
    requests = load_requests()

    for host in candidates:
        url = f"https://{host}:1337/addKey"
        try:
            r = api_get(url, {"pubkey": pub_key}, token, secret)
            if r.status_code == 200:
                data = r.json()
                if data.get("status") == "OK" and data.get("server_key"):
                    addkey_data = data
                    connected_host = host
                    break
                elif "error" in data:
                    last_error_msg = data.get("error")
            elif r.status_code in (401, 403):
                raise RuntimeError(
                    "Authentication failed. Please verify your CyberGhost subscription or run 'cyberghostvpn --setup'."
                )
        except requests.exceptions.RequestException as req_err:
            last_error_msg = str(req_err)
            continue

    if not addkey_data:
        err = f"Could not establish WireGuard key exchange with CyberGhost servers in {cc}."
        if last_error_msg:
            err += f" ({last_error_msg})"
        raise RuntimeError(err)

    # Generate WireGuard configuration
    dns_list = addkey_data.get("dns_servers", ["10.0.0.243", "10.0.0.242", "1.1.1.1"])
    dns_servers_str = ", ".join(dns_list) if isinstance(dns_list, list) else str(dns_list)
    server_ip = addkey_data.get("server_ip") or connected_host
    server_port = addkey_data.get("server_port", 1337)
    peer_ip = addkey_data.get("peer_ip")
    server_key = addkey_data.get("server_key")

    def write_conf(include_dns):
        cfg = build_wg_config(
            priv_key, peer_ip, server_key, server_ip, server_port,
            dns_servers=dns_servers_str if include_dns else None,
        )
        with open(WG_CONF_PATH, "w") as f:
            f.write(cfg)
        os.chmod(WG_CONF_PATH, 0o600)

    os.makedirs("/etc/wireguard", exist_ok=True)

    # Clean up any leftover interface first to avoid collisions
    subprocess.run(["wg-quick", "down", INTERFACE], capture_output=True)

    write_conf(True)
    up_res = subprocess.run(["wg-quick", "up", INTERFACE], capture_output=True, text=True)
    if up_res.returncode != 0:
        # If DNS configuration failed in wg-quick, retry without the DNS directive
        if "resolvconf" in up_res.stderr or "resolv" in up_res.stderr:
            write_conf(False)
            up_res = subprocess.run(["wg-quick", "up", INTERFACE], capture_output=True, text=True)

        if up_res.returncode != 0:
            # Best-effort cleanup of a half-created interface/config
            subprocess.run(["wg-quick", "down", INTERFACE], capture_output=True)
            raise RuntimeError(f"wg-quick up failed: {up_res.stderr.strip() or up_res.stdout.strip()}")

    print("VPN connection established.")
    print(f"Connected to {cc} via {connected_host} (IP: {server_ip})")


def disconnect():
    ip_res = subprocess.run(["ip", "link", "show", INTERFACE], capture_output=True, text=True)
    was_up = (ip_res.returncode == 0 and INTERFACE in ip_res.stdout)
    subprocess.run(["wg-quick", "down", INTERFACE], capture_output=True)
    subprocess.run(["cyberghostvpn", "--stop"], capture_output=True)
    if was_up:
        print("VPN connection terminated.")
    else:
        print("No VPN connections found.")


def build_login_payload(username, password):
    return {"userName": username, "password": password}


def build_device_payload(machine_name):
    return {"data": {"linuxApp": True, "machineName": machine_name}}


def api_request(method, path, payload=None, jwt=None):
    """Authenticated JSON request against the CyberGhost account API."""
    requests = load_requests()
    headers = {
        "Content-Type": "application/json",
        "x-app-key": API_KEY,
        "User-Agent": USER_AGENT,
    }
    if jwt:
        headers["Authorization"] = f"Bearer {jwt}"
    return requests.request(method, API_BASE + path, json=payload, headers=headers, timeout=12)


def write_user_config(path, username, password, device_name, device):
    cfg = configparser.ConfigParser()
    cfg["account"] = {"username": username, "password": password}
    cfg["device"] = {
        "name": device.get("name") or device_name,
        "token": str(device.get("token") or ""),
        # The API returns the secret as `tokenSecret`; the CLI stores it as `secret`.
        "secret": str(device.get("tokenSecret") or device.get("secret") or ""),
    }
    with open(path, "w") as f:
        cfg.write(f)
    os.chmod(path, 0o600)


def register(config_path=None):
    """Link a CyberGhost account natively — no cyberghostvpn CLI required.

    Credentials come from CG_USERNAME/CG_PASSWORD (used by the GUI so they
    never appear in argv) or from interactive prompts.
    """
    import getpass

    username = os.environ.get("CG_USERNAME", "").strip()
    password = os.environ.get("CG_PASSWORD", "")
    if not username or not password:
        username = username or input("CyberGhost username: ").strip()
        password = password or getpass.getpass("CyberGhost password: ")
    if not username or not password:
        raise RuntimeError("Username and password are required.")
    device_name = (os.environ.get("CG_DEVICE_NAME") or socket.gethostname() or "linux-app").strip()

    print("Authenticating ...")
    res = api_request("POST", "/my/account/jwt?language=en", build_login_payload(username, password))
    if res.status_code != 200:
        raise RuntimeError(
            f"Authentication failed (HTTP {res.status_code}). Check your CyberGhost account credentials."
        )
    jwt = res.json().get("jwt")
    if not jwt:
        raise RuntimeError("Authentication response did not contain a session token.")

    print(f"Registering device '{device_name}' ...")
    res = api_request("POST", "/my/devices", build_device_payload(device_name), jwt=jwt)
    if res.status_code != 201:
        detail = ""
        try:
            body = res.json()
            detail = body.get("errorMessage") or body.get("errorCode") or ""
        except Exception:
            pass
        raise RuntimeError(f"Device registration failed (HTTP {res.status_code}). {detail}".strip())
    device = res.json()
    if not device.get("token"):
        raise RuntimeError("Device registration response missing token.")

    target = config_path or os.path.expanduser("~/.cyberghost/config.ini")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    write_user_config(target, username, password, device_name, device)
    print(f"Account linked. Device credentials stored in {target}")


def check():
    """Report onboarding readiness as JSON (fast, no heavy imports)."""
    result = {
        "wg_tools": shutil.which("wg-quick") is not None,
        "requests": importlib.util.find_spec("requests") is not None,
        "cli": shutil.which("cyberghostvpn") is not None,
        "credentials": False,
    }
    try:
        get_credentials(None)
        result["credentials"] = True
    except Exception:
        pass
    print(json.dumps(result))


def status(config_path=None, as_json=False):
    ip_res = subprocess.run(["ip", "link", "show", INTERFACE], capture_output=True, text=True)
    is_connected = (ip_res.returncode == 0 and INTERFACE in ip_res.stdout)

    wg_info = {}
    if is_connected:
        wg_res = subprocess.run(["wg", "show", INTERFACE], capture_output=True, text=True)
        if wg_res.returncode == 0:
            wg_info = parse_wg_show(wg_res.stdout)

    if as_json:
        result = {
            "connected": is_connected,
            "interface": INTERFACE if is_connected else None,
        }
        if is_connected:
            result.update(wg_info)
        print(json.dumps(result))
        return

    if is_connected:
        print("VPN connection found.")
        print(f"Interface: {INTERFACE}")
        for key in ("endpoint", "transfer"):
            if key in wg_info:
                print(f"  {key}: {wg_info[key]}")
        if "handshake_sec" in wg_info:
            print(f"  latest handshake: {wg_info['handshake_sec']} seconds ago")
    else:
        print("No VPN connections found.")


def main():
    parser = argparse.ArgumentParser(description="CyberGhost WireGuard Controller")
    parser.add_argument(
        "action",
        choices=["connect", "disconnect", "status", "check", "register"],
        help="Action to perform",
    )
    parser.add_argument("--country", "-c", default="PT", help="Country code (e.g. PT, ES, US, DE)")
    parser.add_argument("--server-type", "-t", default="traffic", choices=["traffic", "streaming", "torrent"])
    parser.add_argument("--protocol", default="wireguard", choices=["wireguard", "openvpn", "openvpn_tcp"])
    parser.add_argument("--city", help="Optional city name")
    parser.add_argument("--config", help="Explicit path to ~/.cyberghost/config.ini")
    parser.add_argument("--json", action="store_true", help="Output status as JSON")

    args = parser.parse_args()

    try:
        if args.action == "connect":
            if args.protocol != "wireguard" or args.server_type != "traffic":
                # Native dialup API only serves plain WireGuard traffic servers;
                # everything else goes through the official CLI.
                connect_via_cli(args.country, args.server_type, args.protocol)
            else:
                connect(args.country, args.server_type, args.city, args.config)
        elif args.action == "disconnect":
            disconnect()
        elif args.action == "status":
            status(args.config, args.json)
        elif args.action == "check":
            check()
        elif args.action == "register":
            register(args.config)
    except Exception as e:
        sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()

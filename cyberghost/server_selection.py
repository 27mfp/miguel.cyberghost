"""Endpoint candidate selection, reachability probing and key exchange."""

import multiprocessing
import multiprocessing.connection
import re
import signal
import socket
import time
from typing import Any, cast

from .constants import (
    DIALUP_CITY_MAP,
    DIALUP_INSTANCES,
    DIALUP_RACKS,
    ENDPOINT_PROBE_BUDGET_SECONDS,
    ENDPOINT_PROBE_GRACE_SECONDS,
    ENDPOINT_PROBE_TIMEOUT_SECONDS,
    MAX_NATIVE_CANDIDATES,
)
from .server_data import known_servers, live_server_inventory, probe_sample, session_usable
from .system import clean_command_error, response_json
from .transport import api_get, load_requests
from .validation import validate_country_code, validate_endpoint_host, validate_server_selector
from .vendor import get_servers_for_country


def _slug(name):
    return re.sub(r"[^a-z0-9]", "", str(name).lower())


def select_native_candidates(country_code, server_type="traffic", city=None, server=None, session=None):
    """Select validated, bounded native WireGuard endpoint candidates.

    Order: an explicit server; the vendor CLI's inventory; CyberGhost's live
    list (session token); probing real names from the user's cache (filled
    by the background sync); and, only as a last resort, a guessed rack pool.
    """
    cc = validate_country_code(country_code)
    selected_server = validate_server_selector(server) if server else None
    cli_servers = [] if city or selected_server else get_servers_for_country(cc, server_type)
    # The vendor CLI's inventory wins when installed; otherwise ask CyberGhost's
    # API directly with the saved session, before falling back to probing.
    live_servers = None if city or selected_server or cli_servers else live_server_inventory(cc, session)

    if city:
        city_slug = _slug(city)
    elif cc in DIALUP_CITY_MAP:
        city_slug = DIALUP_CITY_MAP[cc]
    elif cli_servers:
        city_slug = _slug(cli_servers[0]["city"])
    else:
        raise RuntimeError(
            f"No known WireGuard city for country '{cc}'. Install the cyberghostvpn CLI for full country coverage."
        )

    # Prefer live load data; retain static candidates only when the CLI is
    # unavailable. Always cap the list so a dead inventory cannot stretch a
    # connect operation beyond its caller's expectations.
    if selected_server:
        candidates = [selected_server]
    elif cli_servers:
        candidates = [item["server"] for item in cli_servers]
    elif live_servers:
        candidates = live_servers
    else:
        reachable = []
        known = known_servers(cc)
        if known == []:
            raise RuntimeError(f"CyberGhost lists no WireGuard servers for {cc}. Choose another country.")
        if known:
            reachable = reachable_endpoints([f"{name}.cg-dialup.net" for name in probe_sample(known)])
        if not reachable:
            # Last resort for countries the sync has not fetched yet.
            pool = [f"{city_slug}-s{rack}-i{idx}.cg-dialup.net" for rack in DIALUP_RACKS for idx in DIALUP_INSTANCES]
            reachable = reachable_endpoints(pool)
        if not reachable:
            raise RuntimeError(
                f"No reachable CyberGhost servers found for {cc}. "
                "Try another country, or install the cyberghostvpn CLI for its live server list."
            )
        candidates = [host[: -len(".cg-dialup.net")] for host in reachable]

    unique: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        if candidate not in seen:
            seen.add(candidate)
            unique.append(candidate)
    candidates = unique
    return cc, [f"{candidate}.cg-dialup.net" for candidate in candidates[:MAX_NATIVE_CANDIDATES]]


def _probe_endpoint(host, port=1337, timeout=ENDPOINT_PROBE_TIMEOUT_SECONDS):
    """Return (host, seconds) when the WireGuard API port accepts TCP, else (host, None)."""
    started = time.monotonic()
    try:
        address = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)[0][4]
        with socket.create_connection((str(address[0]), int(address[1])), timeout=timeout):
            pass
    except OSError:
        return host, None
    return host, time.monotonic() - started


def _probe_worker(host, output):
    """Isolate blocking NSS resolution so the parent can enforce its deadline."""
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    try:
        output.send(_probe_endpoint(host))
    finally:
        output.close()


def reachable_endpoints(hosts, budget=ENDPOINT_PROBE_BUDGET_SECONDS, grace=ENDPOINT_PROBE_GRACE_SECONDS):
    """Probe DNS/TCP in killable workers within a total deadline, without credentials."""
    if not hosts or budget <= 0:
        return []
    # Omarchy is Linux. Explicit fork also keeps worker startup inexpensive.
    context = multiprocessing.get_context("fork")
    deadline = time.monotonic() + budget
    first_answer_at = None
    answered: list[tuple[str, float]] = []
    pending: dict[Any, Any] = {}
    workers: list[Any] = []
    remaining_hosts = iter(hosts)

    def start_worker(host):
        reader, writer = context.Pipe(duplex=False)
        process = context.Process(target=_probe_worker, args=(host, writer))
        try:
            process.start()
        except BaseException:
            reader.close()
            writer.close()
            raise
        writer.close()
        workers.append(process)
        pending[reader] = process

    try:
        for _ in range(min(16, len(hosts))):
            if time.monotonic() >= deadline:
                break
            start_worker(next(remaining_hosts))
        while pending and len(answered) < MAX_NATIVE_CANDIDATES:
            limit = deadline
            if first_answer_at is not None and grace is not None:
                limit = min(deadline, first_answer_at + grace)
            remaining = limit - time.monotonic()
            if remaining <= 0:
                break
            for waited in multiprocessing.connection.wait(pending, timeout=remaining):
                reader = cast("Any", waited)
                process = pending.pop(reader)
                try:
                    host, latency = reader.recv()
                except EOFError:
                    latency = None
                finally:
                    reader.close()
                process.join(timeout=0)
                if latency is not None:
                    answered.append((host, latency))
                    if first_answer_at is None:
                        first_answer_at = time.monotonic()
                if len(answered) >= MAX_NATIVE_CANDIDATES or time.monotonic() >= limit:
                    break
                next_host = next(remaining_hosts, None)
                if next_host is not None:
                    start_worker(next_host)
    finally:
        # Kill all workers before joining any: no resolver can hold process exit.
        for process in workers:
            if process.is_alive():
                process.kill()
        for process in workers:
            process.join()
            process.close()
        for reader in pending:
            reader.close()
    return [host for host, _ in sorted(answered, key=lambda item: item[1])]


def probe_servers(country_codes, session=None):
    """Reachability report per country, for diagnostics.

    The probe itself sends no credentials. With a usable session it also lists
    what CyberGhost's own server API returns, to compare the two.
    """
    report: dict[str, dict[str, Any]] = {}
    for code in country_codes:
        cc = validate_country_code(code)
        city = DIALUP_CITY_MAP.get(cc)
        if not city:
            report[cc] = {"city": None, "reachable": []}
            continue
        known = known_servers(cc)
        names = (
            probe_sample(known)
            if known
            else [f"{city}-s{rack}-i{idx}" for rack in DIALUP_RACKS for idx in DIALUP_INSTANCES]
        )
        found = reachable_endpoints([f"{name}.cg-dialup.net" for name in names], budget=8, grace=None)
        report[cc] = {"city": city, "known": len(known or []), "reachable": [host.split(".")[0] for host in found]}
        if known == []:
            report[cc]["no_wireguard"] = True
        if session_usable((session or {}).get("jwt", "")):
            report[cc]["live"] = live_server_inventory(cc, session) or []
    return report


def exchange_wireguard_key(candidates, pub_key, token, secret, country_code, deadline):
    """Perform bounded key exchange against the selected endpoint candidates."""
    requests = load_requests()
    addkey_data = None
    connected_host = None
    last_error_msg = None

    for host in candidates:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            last_error_msg = "WireGuard connection attempt timed out"
            break
        safe_host = validate_endpoint_host(host)
        url = f"https://{safe_host}:1337/addKey"
        try:
            response = api_get(
                url,
                {"pubkey": pub_key},
                token,
                secret,
                timeout=(min(3.5, remaining), min(3.5, remaining)),
                deadline=deadline,
            )
            if response.status_code == 200:
                data = response_json(response)
                if data.get("status") == "OK" and data.get("server_key"):
                    addkey_data = data
                    connected_host = safe_host
                    break
                if "error" in data:
                    last_error_msg = str(data.get("error"))[:256]
            elif response.status_code in (401, 403):
                raise RuntimeError(
                    "Authentication failed. Verify your CyberGhost subscription, then use Link account "
                    "in the plugin to refresh your device credentials."
                )
            else:
                last_error_msg = f"CyberGhost API returned HTTP {response.status_code}"
        except requests.exceptions.RequestException as req_err:
            last_error_msg = clean_command_error(req_err, "Network request failed")[:256]
        except RuntimeError as api_err:
            # TLS/response validation errors are expected when the vendor
            # rotates its native dialup inventory. Try the remaining hosts.
            last_error_msg = clean_command_error(api_err, "CyberGhost API request failed")[:256]

    if not addkey_data:
        err = f"Could not establish WireGuard key exchange with CyberGhost servers in {country_code}."
        if last_error_msg:
            err += f" ({last_error_msg})"
        if last_error_msg and re.search(r"TLS|certificate|hostname|SSL", last_error_msg, re.I):
            err += " Check your system clock, CA certificates and network, then retry or refresh with Link account."
        raise RuntimeError(err)
    return addkey_data, connected_host

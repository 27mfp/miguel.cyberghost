#!/usr/bin/python3 -Es
"""
CyberGhost VPN WireGuard backend for Omarchy.

Negotiates WireGuard keys with CyberGhost and runs the tunnel as an in-memory
NetworkManager connection. It runs as the desktop user: NetworkManager and
Polkit authorize the network change, so no root helper is installed.
"""

import argparse
import base64
import binascii
import concurrent.futures
import configparser
import contextlib
import fcntl
import importlib.util
import io
import ipaddress
import json
import os
import pwd
import random
import re
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import urlsplit, urlunsplit

INTERFACE = "cyberghost"
NM_CONNECTION_NAME = "CyberGhost VPN"
# Fixed namespace for the per-user profile UUID (see connection_uuid()).
NM_UUID_NAMESPACE = uuid.UUID("0b5c3f7e-9a61-4d2e-8f3b-6c1d2a7e4b90")
NM_DNS_PRIORITY = -50
NM_REQUIRED_PERMISSIONS = ("network-control", "settings.modify.own")
NMCLI_NOT_FOUND = 10
# Pre-1.7 releases installed these; they are detected only to offer removal.
LEGACY_HELPER_PATH = "/usr/local/bin/cyberghost-runner"
LEGACY_POLKIT_RULE_PATH = "/etc/polkit-1/rules.d/50-cyberghost.rules"
LEGACY_POLKIT_MARKER_RELATIVE_PATH = os.path.join(".local", "state", "cyberghost", "polkit-rule-installed")
LEGACY_POLKIT_MARKER_CONTENT = "cyberghost-polkit-rule-v1"
PLUGIN_VERSION = "1.7.0"
MAX_CONFIG_BYTES = 64 * 1024
MAX_HTTP_RESPONSE_BYTES = 64 * 1024
MAX_SUBPROCESS_INPUT_BYTES = 64 * 1024
MAX_SUBPROCESS_OUTPUT_BYTES = 64 * 1024
NATIVE_CONNECT_BUDGET_SECONDS = 120
ACCOUNT_API_BUDGET_SECONDS = 30
MAX_NATIVE_CANDIDATES = 12
ACTIONS = {"connect", "disconnect", "logout"}

# CyberGhost account/device API — endpoints and the app key below are the same
# ones embedded in the official cyberghostvpn CLI (verified against its 1.4.1 build).
API_BASE = "https://v2-api.cyberghostvpn.com/v2"
DEFAULT_API_KEY = "QzgDsDNUXlgF9jehkTHHtBJwwI4RyInkZQDRJfLyz"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36"
)

# Country Code -> Primary CyberGhost city slug.
# Mirrors the country list in Countries.js — keep both in sync
# (tests/test_validation.py enforces coverage). A wrong/unknown slug fails
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

# The vendor's city spelling and its dialup hostname prefix are not always the
# same. Keep CITY_MAP suitable for CLI inventory queries, and override only the
# endpoint prefix where the live DNS differs. Verified by resolving and
# TLS-checking the nodes (see `probe`): Ukraine serves kiev-*, Italy milano-*
# (also rome-*), Israel jerusalem-*, Kazakhstan astana-* and Morocco rabat-*.
DIALUP_CITY_MAP = {
    **CITY_MAP,
    "UA": "kiev",
    "IT": "milano",
    "IL": "jerusalem",
    "KZ": "astana",
    "MA": "rabat",
    # From CyberGhost's own server list: Bosnia is served from Travnik
    # and China from Shenzhen (the old "hongkong" guess landed in Hong Kong).
    "BA": "travnik",
    "CN": "shenzhen",
}

# Without the vendor CLI there is no live inventory. Rather than trusting a
# few fixed racks (dead racks stall connect; many countries use others), probe
# this pool and try only hosts that answer, fastest first. Racks seen live
# range from 401 to 418.
DIALUP_RACKS = tuple(range(401, 421))
DIALUP_INSTANCES = ("01", "02", "03")
ENDPOINT_PROBE_BUDGET_SECONDS = 4.0
ENDPOINT_PROBE_TIMEOUT_SECONDS = 2.5
ENDPOINT_PROBE_GRACE_SECONDS = 1.0
LIVE_INVENTORY_BUDGET_SECONDS = 6
# Real server names live in a per-user cache built from the user's own
# account: connects refresh their country, and a paced background sync fills
# every country while the login session (about a day) is valid. Nothing is
# bundled or shared between users.
SERVER_CACHE_RELATIVE_PATH = os.path.join(".cache", "cyberghost", "servers.json")
SYNC_LOCK_RELATIVE_PATH = os.path.join(".cache", "cyberghost", "sync.lock")
SYNC_PACE_SECONDS = 5
SYNC_REFRESH_SECONDS = 7 * 86400
SYNC_STATE_RELATIVE_PATH = os.path.join(".cache", "cyberghost", "sync-state.json")
# After a rate limit or rejected session, wait before any automatic restart.
SYNC_BACKOFF_SECONDS = {429: 15 * 60, 401: 60 * 60}
MAX_SERVER_LIST_BYTES = 2 * 1024 * 1024
# Probing every known server of a large country would be slow and noisy.
PROBE_SAMPLE_SIZE = 48
# About 500 bytes per server; the largest countries list a few thousand.
MAX_INVENTORY_RESPONSE_BYTES = 4 * 1024 * 1024

_HANDSHAKE_UNITS = {"second": 1, "minute": 60, "hour": 3600, "day": 86400}


def run_bounded(
    command,
    timeout=30,
    input_data=None,
    max_output_bytes=MAX_SUBPROCESS_OUTPUT_BYTES,
    env=None,
):
    """Run a command with a hard output and wall-clock limit."""
    if not command:
        raise ValueError("Command must not be empty")
    argv = [str(part) for part in command]
    if input_data is not None and not isinstance(input_data, bytes):
        input_data = str(input_data).encode("utf-8")
    if input_data is not None and len(input_data) > MAX_SUBPROCESS_INPUT_BYTES:
        raise RuntimeError(f"Command input exceeded {MAX_SUBPROCESS_INPUT_BYTES} bytes")

    # argv is built from absolute system binaries or validated fixed arguments.
    process = subprocess.Popen(  # noqa: S603
        argv,
        stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        env=env,
    )

    selector = selectors.DefaultSelector()
    streams = ((process.stdout, "stdout"), (process.stderr, "stderr"))
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    input_offset = 0
    try:
        for stream, name in streams:
            selector.register(stream, selectors.EVENT_READ, name)
        if process.stdin is not None:
            os.set_blocking(process.stdin.fileno(), False)
            if input_data:
                selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
            else:
                process.stdin.close()

        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, timeout)
            events = selector.select(remaining)
            if not events:
                raise subprocess.TimeoutExpired(argv, timeout)
            for key, _ in events:
                if key.data == "stdin":
                    try:
                        written = os.write(process.stdin.fileno(), input_data[input_offset:])
                        input_offset += written
                    except BrokenPipeError:
                        input_offset = len(input_data)
                    if input_offset >= len(input_data):
                        selector.unregister(process.stdin)
                        process.stdin.close()
                    continue

                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                total = len(buffers["stdout"]) + len(buffers["stderr"]) + len(chunk)
                if total > max_output_bytes:
                    raise RuntimeError(f"Command output exceeded {max_output_bytes} bytes")
                buffers[key.data].extend(chunk)

        # A child may close both output streams and continue running. Keep the
        # same deadline while waiting for its exit as while reading its output.
        exit_code = process.wait(timeout=max(0, deadline - time.monotonic()))
        return subprocess.CompletedProcess(
            argv,
            exit_code,
            buffers["stdout"].decode("utf-8", errors="replace"),
            buffers["stderr"].decode("utf-8", errors="replace"),
        )
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    finally:
        selector.close()
        for stream, _ in streams:
            if stream and not stream.closed:
                stream.close()
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()


def read_response_bounded(response, max_bytes=MAX_HTTP_RESPONSE_BYTES, deadline=None):
    """Read a streamed HTTP body with byte and optional wall-clock limits."""
    content_length = response.headers.get("Content-Length")
    if content_length and content_length.isdigit() and int(content_length) > max_bytes:
        response.close()
        raise RuntimeError(f"HTTP response exceeds {max_bytes} bytes")

    chunks = []
    total = 0
    try:
        for chunk in response.iter_content(chunk_size=8192):
            if deadline is not None and time.monotonic() >= deadline:
                raise RuntimeError("HTTP response timed out")
            if not chunk:
                continue
            total += len(chunk)
            if total > max_bytes:
                raise RuntimeError(f"HTTP response exceeds {max_bytes} bytes")
            chunks.append(chunk)
    finally:
        response.close()
    return b"".join(chunks)


def response_json(response):
    """Decode a body captured by read_response_bounded and require an object."""
    try:
        data = json.loads(getattr(response, "_cyberghost_body", b"{}").decode("utf-8"))
    except (AttributeError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("CyberGhost returned invalid JSON") from exc
    if not isinstance(data, dict):
        raise RuntimeError("CyberGhost returned an unexpected JSON shape")
    return data


# ==============================================================================
# Strict input & response validation (blocks WireGuard configuration injection)
# ==============================================================================


def validate_wireguard_key(key: str) -> str:
    """Validate a WireGuard Base64 32-byte key against directive/newline injection."""
    if not isinstance(key, str):
        raise ValueError("WireGuard key must be a string")
    k = key.strip()
    if any(c in k for c in ("\r", "\n", "\t", " ", ";", "#")):
        raise ValueError("WireGuard key contains whitespace or control characters")
    if not re.match(r"^[A-Za-z0-9+/]{43}=$", k):
        raise ValueError("Invalid WireGuard key format (expected 44-char base64 ending in '=')")
    try:
        raw = base64.b64decode(k.encode("ascii"), validate=True)
        if len(raw) != 32:
            raise ValueError(f"WireGuard key length is {len(raw)} bytes, expected 32 bytes")
    except (binascii.Error, ValueError) as e:
        raise ValueError(f"Invalid WireGuard Base64 key: {e}") from e
    return k


def validate_ip(ip_str: str) -> str:
    """Validate IPv4 or IPv6 address string with no trailing chars or newlines."""
    if not isinstance(ip_str, str):
        raise ValueError("IP address must be a string")
    s = ip_str.strip()
    if any(c in s for c in ("\r", "\n", "\t", " ", ";", "#", "/", "\\")):
        raise ValueError("IP address contains invalid whitespace/control characters")
    try:
        ip = ipaddress.ip_address(s)
        return str(ip)
    except ValueError as e:
        raise ValueError(f"Invalid IP address '{s}': {e}") from e


def validate_port(port) -> int:
    """Validate network port number (1-65535)."""
    try:
        p = int(port)
        if not (1 <= p <= 65535):
            raise ValueError(f"Port {p} out of valid range (1-65535)")
        return p
    except (TypeError, ValueError) as e:
        raise ValueError(f"Invalid port value '{port}': {e}") from e


def validate_country_code(country_code) -> str:
    """Validate an ISO-style two-letter country code before passing it to a CLI."""
    if not isinstance(country_code, str):
        raise ValueError("Country code must be a string")
    code = country_code.strip().upper()
    if not re.fullmatch(r"[A-Z]{2}", code):
        raise ValueError(f"Invalid country code '{country_code}'")
    return code


def validate_server_selector(server) -> str:
    """Validate a CyberGhost instance name before using it as a dialup host."""
    if not isinstance(server, str):
        raise ValueError("Server selector must be a string")
    value = server.strip().lower()
    if len(value) > 128 or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*-s\d+-i\d+", value):
        raise ValueError(f"Invalid CyberGhost server selector '{server}'")
    return value


def validate_endpoint_host(host: str) -> str:
    """Validate endpoint host: either a valid IP or strict RFC 1123 DNS hostname."""
    if not isinstance(host, str):
        raise ValueError("Host must be a string")
    h = host.strip()
    if any(c in h for c in ("\r", "\n", "\t", " ", ";", "#", "/", "\\", "'", '"')):
        raise ValueError("Host contains invalid control/special characters")
    # Try IP first
    try:
        return str(ipaddress.ip_address(h))
    except ValueError:
        pass
    # Strict hostname check (max 253 chars, valid labels)
    if len(h) > 253 or not re.match(
        r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$", h
    ):
        raise ValueError(f"Invalid hostname format: '{h}'")
    return h


def validate_dns_servers(dns_input, require_nonempty=False) -> str:
    """Validate a comma-separated string or list of DNS server IP addresses."""
    if dns_input is None:
        if require_nonempty:
            raise ValueError("At least one VPN DNS server is required")
        return ""
    if isinstance(dns_input, str):
        raw_list = [item.strip() for item in dns_input.split(",") if item.strip()]
    elif isinstance(dns_input, (list, tuple)):
        raw_list = [str(item).strip() for item in dns_input if str(item).strip()]
    else:
        raise ValueError("DNS servers must be a list or comma-separated string")

    if require_nonempty and not raw_list:
        raise ValueError("At least one VPN DNS server is required")

    validated = []
    for entry in raw_list:
        validated.append(validate_ip(entry))
    result = ", ".join(validated)
    if require_nonempty and not result:
        raise ValueError("At least one VPN DNS server is required")
    return result


def load_requests():
    """Import requests lazily so lightweight `status` polls skip the cost."""
    try:
        import requests
    except ImportError as exc:
        raise RuntimeError(
            "The 'requests' library is required for the native WireGuard path. "
            "Please install python-requests (e.g. 'sudo pacman -S python-requests')."
        ) from exc
    return requests


def _getaddrinfo_bounded(host, port, timeout):
    """Resolve one host without allowing libc DNS to defeat the connect budget."""
    if timeout is None or timeout <= 0:
        raise TimeoutError("DNS resolution timed out")
    if threading.current_thread() is not threading.main_thread():
        return socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)

    def on_alarm(signum, frame):
        raise TimeoutError("DNS resolution timed out")

    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_timer = signal.setitimer(signal.ITIMER_REAL, 0)
    signal.signal(signal.SIGALRM, on_alarm)
    signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        return socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    finally:
        signal.setitimer(signal.ITIMER_REAL, *previous_timer)
        signal.signal(signal.SIGALRM, previous_handler)


def dialup_tls_target(url, timeout=3.5):
    """Return a canonical TLS URL and the IP behind a dialup endpoint.

    Current CyberGhost nodes resolve from ``*-sNNN-iNN.cg-dialup.net`` but
    present certificates for ``*-rackNNN.nodes.gen4.ninja``. Keep DNS pinning
    to the original dialup record while using the certificate's canonical
    hostname for SNI and hostname validation.
    """
    parsed = urlsplit(url)
    host = parsed.hostname or ""
    match = re.fullmatch(r"([a-z0-9-]+)-s(\d+)-i\d+\.cg-dialup\.net", host, re.I)
    if not match:
        return url, None
    if parsed.scheme.lower() != "https":
        raise RuntimeError("CyberGhost endpoint must use HTTPS")

    try:
        addresses = _getaddrinfo_bounded(host, parsed.port or 443, timeout)
    except TimeoutError as exc:
        raise RuntimeError(f"Could not resolve CyberGhost endpoint {host}: DNS timed out") from exc
    except OSError as exc:
        raise RuntimeError(f"Could not resolve CyberGhost endpoint {host}") from exc
    if not addresses:
        raise RuntimeError(f"Could not resolve CyberGhost endpoint {host}")

    connect_host = addresses[0][4][0]
    canonical_host = f"{match.group(1).lower()}-rack{match.group(2)}.nodes.gen4.ninja"
    netloc = canonical_host
    if parsed.port:
        netloc += f":{parsed.port}"
    canonical_url = urlunsplit((parsed.scheme, netloc, parsed.path, parsed.query, parsed.fragment))
    return canonical_url, connect_host


# Cache for the pinned TLS adapter classes (see mapped_https_get).
# Populated lazily on first use so lightweight commands (status, check)
# never pay the cost of importing requests/urllib3.
_MAPPED_ADAPTER_CLASSES = None
_MAPPED_HTTPS_PROBE_OK = None  # None = not yet probed
_MAPPED_HTTPS_PROBE_ERROR = (
    "Installed requests/urllib3 does not support the pinned CyberGhost TLS adapter; "
    "refusing to send credentials without endpoint pinning. Upgrade python-requests."
)


def _build_mapped_adapter_classes():
    """Return (MappedConnection, MappedHTTPSConnectionPool, MappedAdapter).

    Built once on first call and cached. Raises RuntimeError if the installed
    requests/urllib3 does not expose the private symbols this adapter hooks
    into. urllib3 does not provide a public adapter API for preserving both
    a custom destination IP and the canonical TLS/SNI hostname, so we fail
    closed instead of silently dropping DNS pinning.
    """
    global _MAPPED_ADAPTER_CLASSES
    if _MAPPED_ADAPTER_CLASSES is not None:
        return _MAPPED_ADAPTER_CLASSES
    from requests.adapters import HTTPAdapter
    from urllib3.connection import HTTPSConnection
    from urllib3.connectionpool import HTTPSConnectionPool
    from urllib3.poolmanager import PoolKey, PoolManager, _default_key_normalizer
    from urllib3.util import connection as urllib3_connection

    class MappedConnection(HTTPSConnection):
        def __init__(self, *args, connect_host=None, **connection_kwargs):
            self._connect_host = connect_host
            super().__init__(*args, **connection_kwargs)

        def _new_conn(self):
            return urllib3_connection.create_connection(
                (self._connect_host or self._dns_host, self.port),
                self.timeout,
                source_address=self.source_address,
                socket_options=self.socket_options,
            )

    class MappedHTTPSConnectionPool(HTTPSConnectionPool):
        ConnectionCls = MappedConnection

    class MappedAdapter(HTTPAdapter):
        def __init__(self, target_host):
            self.target_host = target_host
            super().__init__()

        def init_poolmanager(self, connections, maxsize, block=False, **pool_kwargs):
            pool_kwargs["connect_host"] = self.target_host
            self.poolmanager = PoolManager(
                num_pools=connections,
                maxsize=maxsize,
                block=block,
                **pool_kwargs,
            )
            self.poolmanager.pool_classes_by_scheme["https"] = MappedHTTPSConnectionPool

            def normalize_pool_key(context):
                try:
                    return _default_key_normalizer(
                        PoolKey,
                        {key: value for key, value in context.items() if key != "connect_host"},
                    )
                except (AttributeError, TypeError, KeyError) as exc:
                    raise RuntimeError(
                        "Installed urllib3 cannot construct the pinned CyberGhost connection pool"
                    ) from exc

            self.poolmanager.key_fn_by_scheme["https"] = normalize_pool_key

    _MAPPED_ADAPTER_CLASSES = (MappedConnection, MappedHTTPSConnectionPool, MappedAdapter)
    return _MAPPED_ADAPTER_CLASSES


def _reset_mapped_https_probe():
    """Reset the probe cache. Tests use this to simulate urllib3 drift; not called at runtime."""
    global _MAPPED_ADAPTER_CLASSES, _MAPPED_HTTPS_PROBE_OK
    _MAPPED_ADAPTER_CLASSES = None
    _MAPPED_HTTPS_PROBE_OK = None


def _ensure_mapped_https_probe():
    """Probe the pinned TLS adapter path once on first use and cache the result.

    urllib3 does not provide a public adapter hook for keeping a custom
    destination IP while presenting a canonical SNI hostname, so this
    project reaches into its private API. A urllib3 release that moves
    those symbols would otherwise fail on the user's first connect with a
    generic network error. Probing here surfaces a clear message before
    any credential-bearing request is sent.
    """
    global _MAPPED_HTTPS_PROBE_OK
    if _MAPPED_HTTPS_PROBE_OK is True:
        return None
    if _MAPPED_HTTPS_PROBE_OK is False:
        raise RuntimeError(_MAPPED_HTTPS_PROBE_ERROR)
    try:
        _MappedConnection, _MappedPool, MappedAdapter = _build_mapped_adapter_classes()
        # init_poolmanager is the brittle step: it depends on PoolManager,
        # pool_classes_by_scheme and the private key normalizer all being
        # present with the expected shapes.
        adapter = MappedAdapter("127.0.0.1")
        adapter.init_poolmanager(1, 1)
    except (ImportError, RuntimeError, AttributeError, TypeError, KeyError) as exc:
        _MAPPED_HTTPS_PROBE_OK = False
        raise RuntimeError(_MAPPED_HTTPS_PROBE_ERROR) from exc
    _MAPPED_HTTPS_PROBE_OK = True
    return None


def mapped_https_get(requests, url, resolve_timeout=3.5, **kwargs):
    """GET a canonical CyberGhost node while connecting to its dialup IP."""
    if urlsplit(url).scheme.lower() != "https":
        raise RuntimeError("CyberGhost API endpoint must use HTTPS")
    canonical_url, connect_host = dialup_tls_target(url, timeout=resolve_timeout)
    if not connect_host:
        session = requests.Session()
        session.trust_env = False
        return session.get(canonical_url, **kwargs)

    # Ensure the pinned adapter path was exercised once. After the probe
    # succeeds the classes are cached, so this is just a cache lookup on
    # subsequent calls.
    _ensure_mapped_https_probe()
    _, _, MappedAdapter = _build_mapped_adapter_classes()

    session = requests.Session()
    # A proxy cannot safely preserve the explicit IP/SNI pairing. The VPN
    # endpoint must be reached directly, while the API's TLS validation stays
    # enabled through the normal system CA store.
    session.trust_env = False
    session.mount("https://", MappedAdapter(connect_host))
    return session.get(canonical_url, **kwargs)


def api_get(url, params, token, secret, timeout=(3.5, 3.5), deadline=None):
    """Authenticated GET with strict TLS verification — fail closed."""
    requests = load_requests()
    try:
        resolve_timeout = min(3.5, deadline - time.monotonic()) if deadline is not None else 3.5
        response = mapped_https_get(
            requests,
            url,
            params=params,
            auth=(token, secret),
            timeout=timeout,
            verify=True,
            allow_redirects=False,
            stream=True,
            resolve_timeout=resolve_timeout,
        )
        response._cyberghost_body = read_response_bounded(response, deadline=deadline)
        return response
    except requests.exceptions.SSLError as ssl_err:
        # Never resend credentials over an unverified channel; a MITM here
        # would capture the account token/secret.
        host = url.split("/")[2] if "/" in url else url
        raise RuntimeError(
            f"TLS certificate verification failed for {host}. Refusing to send credentials "
            "over an unverified connection (check system CA certificates / proxy)."
        ) from ssl_err


def _slug(name):
    return re.sub(r"[^a-z0-9]", "", str(name).lower())


def validate_streaming_service(service) -> str:
    """Accept a CLI streaming profile name without control characters or huge argv."""
    if not isinstance(service, str):
        raise ValueError("Streaming service must be a string")
    value = service.strip()
    if not value or len(value) > 128 or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("Invalid streaming service name")
    return value


def validate_api_credential(value, label):
    """Keep token/secret values bounded and safe to place in HTTP headers."""
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise RuntimeError(f"Invalid {label} in CyberGhost configuration")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise RuntimeError(f"Invalid {label} in CyberGhost configuration")
    return value


def api_app_key():
    """Return the vendor app key, allowing documented rotation without a release."""
    return validate_api_credential(os.environ.get("CG_APP_KEY", DEFAULT_API_KEY), "application key")


def validate_config_text(value, label, max_length):
    """Validate bounded, single-line text before storing it in INI state."""
    if not isinstance(value, str):
        raise RuntimeError(f"Invalid {label} in CyberGhost configuration")
    text = value.strip()
    if not text or len(text) > max_length or any(ord(char) < 32 or ord(char) == 127 for char in text):
        raise RuntimeError(f"Invalid {label} in CyberGhost configuration")
    return text


def clean_command_error(text, fallback="Command failed"):
    """Keep user-facing command errors useful without leaking Python tracebacks."""
    raw = str(text or "")[:8192]
    lines = raw.splitlines()
    saw_traceback = "Traceback (most recent call last):" in raw or 'File "' in raw
    for line in reversed(lines):
        clean = line.strip()
        if not clean:
            continue
        # PyInstaller appends this generic footer after the useful exception.
        if re.match(r"\[\d+\] Failed to execute script .*due to unhandled exception!?$", clean):
            continue
        if re.search(r"The key [\"\'](?:password|username)[\"\'] does not exist in section [\"\']account[\"\']", clean):
            return "CyberGhost CLI account setup is incomplete. Run cyberghostvpn --setup in a terminal, then refresh."
        if clean in {
            "Traceback (most recent call last):",
            "During handling of the above exception, another exception occurred:",
            "The above exception was the direct cause of the following exception:",
        }:
            saw_traceback = True
            continue
        if clean.startswith('File "') or clean.startswith("[Previous line repeated") or clean == "^":
            saw_traceback = True
            continue
        if clean.startswith("Error:"):
            clean = clean[6:].strip()
        if saw_traceback and not re.search(
            r"error|exception|failed|unable|certificate|hostname|network|timeout", clean, re.I
        ):
            continue
        if clean:
            return clean[:512]
    return fallback[:512]


def find_config_path(override_path=None):
    if override_path:
        return os.path.abspath(os.path.expanduser(override_path))

    env_override = os.environ.get("CYBERGHOST_CONFIG")
    if env_override:
        return os.path.abspath(os.path.expanduser(env_override))

    return user_config_path()


def invoking_user():
    return pwd.getpwuid(os.getuid())


def user_config_path():
    return os.path.join(invoking_user().pw_dir, ".cyberghost", "native.ini")


def legacy_config_path():
    return os.path.join(invoking_user().pw_dir, ".cyberghost", "config.ini")


def validate_user_config_path(path):
    """Keep account state inside the invoking user's private CyberGhost directory."""
    expected = os.path.abspath(user_config_path())
    candidate = os.path.abspath(os.path.expanduser(path or expected))
    if os.path.commonpath((candidate, os.path.dirname(expected))) != os.path.dirname(expected):
        raise RuntimeError("Configuration path must stay inside ~/.cyberghost")
    if os.path.basename(candidate) not in ("native.ini", "config.ini"):
        raise RuntimeError("Configuration path must be ~/.cyberghost/native.ini or the legacy config.ini")
    config_dir = os.path.dirname(candidate)
    if os.path.lexists(config_dir) and os.path.islink(config_dir):
        raise RuntimeError("CyberGhost config directory must not be a symlink")
    return candidate


def load_account(config_path=None):
    """Read device credentials plus display metadata from the active config."""
    path = find_config_path(config_path)
    # Read-only compatibility: never rewrite the vendor CLI's credentials.
    # A present but invalid native file must fail closed, not fall back.
    if path == user_config_path() and not os.path.lexists(path):
        path = legacy_config_path()
    if not os.path.exists(path):
        raise RuntimeError(
            f"Configuration file not found: {path}. Please link your account or run 'cyberghostvpn --setup' first."
        )
    # O_NONBLOCK keeps a FIFO from stalling the runner inside open(); the
    # S_ISREG check below then rejects it.
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        if os.path.islink(path):
            raise RuntimeError(f"Configuration file must not be a symlink: {path}") from exc
        raise RuntimeError(f"Configuration file cannot be opened safely: {path}") from exc

    try:
        file_stat = os.fstat(fd)
        if not stat.S_ISREG(file_stat.st_mode):
            raise RuntimeError(f"Configuration file must be a regular file: {path}")
        if file_stat.st_size > MAX_CONFIG_BYTES:
            raise RuntimeError(f"Configuration file {path} exceeds maximum size limit (64KB).")
        if file_stat.st_mode & 0o077:
            raise RuntimeError(f"Configuration file must be private (mode 600): {path}")
        if file_stat.st_uid != os.getuid():
            raise RuntimeError("Configuration file must belong to the current user")

        with os.fdopen(fd, "r", encoding="utf-8", errors="strict") as config_file:
            fd = None
            cfg = configparser.ConfigParser(interpolation=None)
            cfg.read_file(config_file)
    except (OSError, UnicodeError, configparser.Error) as e:
        raise RuntimeError(f"Failed to parse config file at {path}: {e}") from e
    finally:
        if fd is not None:
            os.close(fd)

    if not cfg.has_section("device") or not cfg.has_option("device", "token") or not cfg.has_option("device", "secret"):
        raise RuntimeError(f"Device credentials missing from {path}. Please run 'cyberghostvpn --setup'")

    token = validate_api_credential(cfg.get("device", "token").strip(), "device token")
    secret = validate_api_credential(cfg.get("device", "secret").strip(), "device secret")
    try:
        username = validate_config_text(cfg.get("account", "username", fallback=""), "username", 256)
    except RuntimeError:
        username = ""
    if os.path.abspath(path) == os.path.abspath(user_config_path()):
        source = "native"
    elif os.path.abspath(path) == os.path.abspath(legacy_config_path()):
        source = "legacy"
    else:
        source = "custom"
    jwt = cfg.get("session", "jwt", fallback="").strip()
    try:
        jwt = validate_api_credential(jwt, "session token") if jwt else ""
    except RuntimeError:
        jwt = ""
    user_id = cfg.get("session", "user_id", fallback="").strip()
    return {
        "token": token,
        "secret": secret,
        "username": username,
        "path": path,
        "source": source,
        "jwt": jwt,
        "user_id": user_id if user_id.isdigit() else "",
    }


def get_credentials(config_path=None):
    account = load_account(config_path)
    return account["token"], account["secret"]


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


def get_servers_for_country(country_code, server_type="traffic"):
    """
    Query the real server instances for a country if cyberghostvpn is present.

    The CLI returns only an aggregate ``Instance 50`` row when called with a
    country alone. Asking for the mapped city returns the actual selectable
    names (for example ``lisbon-s405-i19``) and their current load. Treating
    the aggregate value as a hostname was the reason the native path skipped
    the best servers and fell back to stale static candidates.

    Returns [] when the CLI is unavailable or output cannot be parsed.
    """
    cc = validate_country_code(country_code)
    st = "traffic" if server_type not in ("torrent", "streaming") else server_type
    try:
        cmd = [system_binary("cyberghostvpn"), f"--{st}", "--country-code", cc]
        city_slug = CITY_MAP.get(cc)
        if city_slug:
            cmd += ["--city", city_slug]
        res = run_bounded(
            cmd,
            timeout=5,
            max_output_bytes=16 * 1024,
        )

        if res.returncode != 0:
            detail = clean_command_error(res.stderr or res.stdout, f"cyberghostvpn exited with code {res.returncode}")
            raise RuntimeError(detail)

        servers = []
        seen = set()
        for line in (res.stdout or "").splitlines()[:256]:
            match = re.match(r"\|\s*(\d+)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(\d+)%\s*\|\s*$", line)
            if not match:
                continue
            city = match.group(2).strip()[:64]
            instance = match.group(3).strip()[:128]
            try:
                server = validate_server_selector(instance)
            except ValueError:
                continue
            load = int(match.group(4))
            if load > 100 or server in seen:
                continue
            seen.add(server)
            servers.append({"city": city, "instance": server, "server": server, "load": load})
        if not servers:
            raise RuntimeError(
                "No selectable servers returned by CyberGhost CLI. Automatic selection remains available."
            )
        servers.sort(key=lambda item: (item["load"], item["server"]))
        return servers
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as exc:
        message = clean_command_error(exc, "server inventory unavailable")
        sys.stderr.write(f"Server inventory unavailable for {cc}: {message}\n")
        return []


def get_streaming_services(country_code):
    """Return streaming profiles reported by the official CLI for a country."""
    cc = validate_country_code(country_code)
    try:
        res = run_bounded(
            [system_binary("cyberghostvpn"), "--streaming", "--country-code", cc],
            timeout=8,
            max_output_bytes=32 * 1024,
        )
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as exc:
        message = clean_command_error(exc, "streaming service discovery unavailable")
        sys.stderr.write(f"Streaming service discovery unavailable for {cc}: {message}\n")
        return []

    services = []
    if res.returncode != 0:
        message = clean_command_error(res.stderr or res.stdout, f"cyberghostvpn exited with code {res.returncode}")
        sys.stderr.write(f"Streaming service discovery unavailable for {cc}: {message}\n")
        return services
    for line in (res.stdout or "").splitlines()[:256]:
        match = re.match(r"\|\s*\d+\s*\|\s*(.*?)\s*\|\s*([A-Z]{2})\s*\|", line)
        if not match:
            continue
        name = match.group(1).strip()
        service_country = match.group(2)
        if not name or service_country != cc:
            continue
        try:
            safe_name = validate_streaming_service(name)
        except ValueError:
            continue
        # SearchableDropdown renders labels through the shell's shared Text
        # component; keep display text inert even if a third-party CLI emits
        # angle brackets while preserving the exact argv value.
        display_name = safe_name.replace("<", "[").replace(">", "]")
        services.append({"value": safe_name, "label": display_name})
    return services


def group_server_names(names):
    """{"lisbon-s405": [1, 2, ...]}: the compact form used on disk."""
    grouped = {}
    for name in names:
        prefix, _, instance = name.rpartition("-i")
        grouped.setdefault(prefix, []).append(int(instance))
    return {prefix: sorted(set(numbers)) for prefix, numbers in sorted(grouped.items())}


def expand_server_names(grouped, limit=20000):
    """Inverse of group_server_names; every name is strictly validated."""
    names = []
    if not isinstance(grouped, dict):
        return names
    for prefix, numbers in grouped.items():
        if not isinstance(prefix, str) or not isinstance(numbers, list):
            continue
        for number in numbers:
            if isinstance(number, bool) or not isinstance(number, int) or not 0 <= number < 10000:
                continue
            try:
                names.append(validate_server_selector(f"{prefix}-i{number:02d}"))
            except ValueError:
                continue
            if len(names) >= limit:
                return names
    return names


def _read_server_list(path):
    try:
        info = os.stat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_SERVER_LIST_BYTES:
            return {}
        with open(path, encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, UnicodeError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def server_cache_path():
    return os.path.join(invoking_user().pw_dir, SERVER_CACHE_RELATIVE_PATH)


def known_servers(country_code):
    """Real server names for a country from the user's cache.

    None means the country has not been fetched yet; an empty list means
    CyberGhost listed no WireGuard servers there. Entries never expire:
    names drift slowly and every connect probes them before use.
    """
    cc = validate_country_code(country_code)
    cached = _read_server_list(server_cache_path()).get("countries", {}).get(cc)
    if not isinstance(cached, dict) or not isinstance(cached.get("servers"), dict):
        return None
    return expand_server_names(cached["servers"])


def remember_servers(country_code, names):
    """Best-effort: keep the latest live list so later fallbacks stay current."""
    path = server_cache_path()
    try:
        directory = os.path.dirname(path)
        os.makedirs(directory, mode=0o700, exist_ok=True)
        data = _read_server_list(path)
        countries = data.get("countries") if isinstance(data.get("countries"), dict) else {}
        countries[validate_country_code(country_code)] = {
            "updated": int(time.time()),
            "servers": group_server_names(names),
        }
        with tempfile.NamedTemporaryFile("w", dir=directory, delete=False, prefix=".servers_", encoding="utf-8") as tf:
            json.dump({"countries": countries}, tf, separators=(",", ":"))
            temp_name = tf.name
        os.replace(temp_name, path)
    except (OSError, ValueError):
        pass


def is_nospy(name):
    # NoSpy servers are a separately sold add-on; use them only as a last choice.
    return name.startswith("nospy")


def probe_sample(names, size=PROBE_SAMPLE_SIZE):
    """Spread a probe across cities and racks, randomly within each."""
    regular = [name for name in names if not is_nospy(name)]
    names = regular or names
    by_prefix = {}
    for name in names:
        by_prefix.setdefault(name.rpartition("-i")[0], []).append(name)
    queues = list(by_prefix.values())
    for queue in queues:
        random.shuffle(queue)
    random.shuffle(queues)
    sample = []
    while queues and len(sample) < size:
        for queue in list(queues):
            if queue:
                sample.append(queue.pop())
            if not queue:
                queues.remove(queue)
            if len(sample) >= size:
                break
    return sample


def jwt_expiry(jwt):
    """Return the token's `exp` (epoch seconds) without verifying it, or None."""
    try:
        payload = jwt.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        expiry = claims.get("exp") if isinstance(claims, dict) else None
        return int(expiry) if isinstance(expiry, (int, float)) and not isinstance(expiry, bool) else None
    except (IndexError, ValueError, TypeError, UnicodeError, binascii.Error):
        return None


def session_usable(jwt, now=None):
    if not jwt:
        return False
    expiry = jwt_expiry(jwt)
    return expiry is None or expiry > (now if now is not None else time.time()) + 60


def account_user_id(jwt):
    """Best-effort numeric account id, which CyberGhost's server filters accept."""
    try:
        res = api_request("GET", "/my/account?fields=(id)&language=en", jwt=jwt, budget=10)
        user_id = str(response_json(res).get("id", "")) if res.status_code == 200 else ""
    except (OSError, RuntimeError, ValueError):
        return ""
    return user_id if user_id.isdigit() else ""


def _number(value):
    """Accept JSON numbers or numeric strings; None for anything else."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    # Signed (coordinates: Lisbon is at -9.13) with up to a float repr's digits.
    if isinstance(value, str) and re.fullmatch(r"-?\d{1,9}(?:\.\d{1,20})?", value.strip()):
        return float(value)
    return None


def account_location(jwt):
    """User id plus CyberGhost's IP-based location, which its server filter requires."""
    res = api_request(
        "GET", "/my/account?fields=(id,location)&language=en", jwt=jwt, budget=LIVE_INVENTORY_BUDGET_SECONDS
    )
    if res.status_code != 200:
        return None
    data = response_json(res)
    location = data.get("location") if isinstance(data.get("location"), dict) else {}
    latitude, longitude = _number(str(location.get("latitude", ""))), _number(str(location.get("longitude", "")))
    user_id = str(data.get("id", ""))
    if latitude is None or longitude is None or not user_id.isdigit():
        return None
    return user_id, latitude, longitude


def parse_live_inventory(data, max_items=8192):
    """Collect instance names and load from CyberGhost's server-filter response.

    The layout is not documented, so walk the JSON (bounded) and accept only
    values that pass the same strict selector validation as the addKey path.
    """
    found = {}
    stack = [(data, 0)]
    visited = 0
    while stack and visited < 4 * max_items:
        node, depth = stack.pop()
        visited += 1
        if depth > 6:
            continue
        if isinstance(node, list):
            stack.extend((item, depth + 1) for item in node[:max_items])
        elif isinstance(node, dict):
            name = None
            for key in ("instance", "real", "name", "displayName", "hostname"):
                value = node.get(key)
                if isinstance(value, str):
                    candidate = value.strip().lower()
                    if candidate.endswith(".cg-dialup.net"):
                        candidate = candidate[: -len(".cg-dialup.net")]
                    # Some display names drop the rack's "s" ("Nairobi-401-i01")
                    # while DNS keeps it (nairobi-s401-i01.cg-dialup.net).
                    candidate = re.sub(r"^([a-z0-9]+(?:-[a-z0-9]+)*?)-(\d+)-i(\d+)$", r"\1-s\2-i\3", candidate)
                    try:
                        name = validate_server_selector(candidate)
                        break
                    except ValueError:
                        continue
            # CyberGhost sends counts as strings ("17") and marks capacity with
            # full="1"; a full server would only reject the key exchange.
            if name and str(node.get("full", "0")).strip() != "1":
                users, capacity = _number(node.get("totalusers")), _number(node.get("Max_Users"))
                load = 100.0
                if users is not None and users >= 0 and capacity and capacity > 0:
                    load = max(0.0, min(100.0, 100.0 * users / capacity))
                found[name] = min(load, found.get(name, 100.0))
            stack.extend((value, depth + 1) for value in node.values() if isinstance(value, (list, dict)))
    return sorted(found, key=lambda host: (is_nospy(host), found[host], host))


def fetch_country_servers(country_code, jwt, where):
    """One filters/74 request. Returns (HTTP status, names or None).

    names is [] only when CyberGhost returned an empty list, which means the
    country has no WireGuard servers; any other unusable body is None.
    """
    cc = validate_country_code(country_code)
    user_id, latitude, longitude = where
    path = (
        f"/my/servers/filters/74?filter_protocol=wireguard&filter_country={cc}"
        f"&filter_user_id={user_id}&filter_user_latitude={latitude}&filter_user_longitude={longitude}"
    )
    res = api_request(
        "GET", path, jwt=jwt, budget=LIVE_INVENTORY_BUDGET_SECONDS, max_bytes=MAX_INVENTORY_RESPONSE_BYTES
    )
    if res.status_code != 200:
        return res.status_code, None
    try:
        data = json.loads(getattr(res, "_cyberghost_body", b"").decode("utf-8"))
    except (UnicodeError, ValueError):
        return res.status_code, None
    if not isinstance(data, list):
        return res.status_code, None
    names = parse_live_inventory(data)
    if data and not names:
        return res.status_code, None  # rows we could not read: not "no servers"
    return res.status_code, names


def live_server_inventory(country_code, session):
    """CyberGhost's own server list for a country, lowest load first, or None."""
    jwt = (session or {}).get("jwt", "")
    if not session_usable(jwt):
        return None
    cc = validate_country_code(country_code)
    try:
        # The filter rejects requests without the user's coordinates. They are
        # fetched per request: IP-based, so they move with the network.
        where = account_location(jwt)
        if where is None:
            sys.stderr.write("Live server list unavailable (no account location); probing servers instead.\n")
            return None
        status_code, names = fetch_country_servers(cc, jwt, where)
    except (OSError, RuntimeError, ValueError) as exc:
        sys.stderr.write(f"Live server list unavailable: {clean_command_error(exc)}\n")
        return None
    if names is None:
        # 401: session expired; 429: rate limited. The fallback still connects.
        sys.stderr.write(f"Live server list unavailable (HTTP {status_code}); probing servers instead.\n")
        return None
    remember_servers(cc, names)
    return names or None


def _sync_state_path():
    return os.path.join(invoking_user().pw_dir, SYNC_STATE_RELATIVE_PATH)


def _sync_blocked_until():
    until = _read_server_list(_sync_state_path()).get("blocked_until")
    return until if isinstance(until, (int, float)) and not isinstance(until, bool) else 0


def _block_sync(seconds, now):
    """Remember a backoff so repeated panel opens cannot restart a limited sync."""
    path = _sync_state_path()
    try:
        with tempfile.NamedTemporaryFile(
            "w", dir=os.path.dirname(path), delete=False, prefix=".sync_", encoding="utf-8"
        ) as tf:
            json.dump({"blocked_until": int(now + seconds)}, tf)
            temp_name = tf.name
        os.replace(temp_name, path)
    except OSError:
        pass


def _session_still_current(jwt):
    """Stop syncing once the user logs out or links a different session."""
    try:
        return load_account(None)["jwt"] == jwt
    except (OSError, RuntimeError, configparser.Error):
        return False


def sync_servers(country_codes=None, pace=SYNC_PACE_SECONDS, refresh=SYNC_REFRESH_SECONDS, now=None):
    """Fill the user's cache from their own account, one country at a time.

    Paced to stay under CyberGhost's rate limit. A 429 or 401 stops the run and
    records a backoff, so reopening the panel cannot keep the account limited.
    Countries refreshed recently are skipped; a failed country is retried on a
    later run. The run also stops as soon as the login it started with is gone.
    """

    def result(synced=0, failed=0, remaining=None, stopped=""):
        return {"synced": synced, "failed": failed, "remaining": remaining, "stopped": stopped}

    try:
        account = load_account(None)
    except (OSError, RuntimeError, configparser.Error):
        return result(stopped="no account")
    jwt = account["jwt"]
    if not session_usable(jwt):
        return result(stopped="no session")
    clock = now if now is not None else time.time()
    if _sync_blocked_until() > clock:
        return result(stopped="backing off")
    lock_path = os.path.join(invoking_user().pw_dir, SYNC_LOCK_RELATIVE_PATH)
    os.makedirs(os.path.dirname(lock_path), mode=0o700, exist_ok=True)
    lock = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0), 0o600)
    synced = failed = 0
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return result(stopped="already running")
        codes = country_codes or sorted(code for code in CITY_MAP if code != "UK")
        cached = _read_server_list(server_cache_path()).get("countries", {})
        todo = []
        for code in codes:
            entry = cached.get(code) if isinstance(cached, dict) else None
            updated = entry.get("updated") if isinstance(entry, dict) else None
            if not isinstance(updated, (int, float)) or clock - updated > refresh:
                todo.append(code)
        if not todo:
            return result(remaining=0)
        try:
            where = account_location(jwt)
        except (OSError, RuntimeError, ValueError) as exc:
            return result(remaining=len(todo), stopped=clean_command_error(exc))
        if where is None:
            return result(remaining=len(todo), stopped="no location")
        for index, code in enumerate(todo):
            if not _session_still_current(jwt):
                return result(synced, failed, len(todo) - index, "logged out")
            try:
                status_code, names = fetch_country_servers(code, jwt, where)
            except (OSError, RuntimeError, ValueError):
                # A timeout or reset on one country must not end the run.
                status_code, names = None, None
            if status_code in (401, 429):
                _block_sync(SYNC_BACKOFF_SECONDS[status_code], time.time())
                return result(synced, failed, len(todo) - index, f"HTTP {status_code}")
            if names is None:
                failed += 1  # unreadable or failed: retried on a later run
            else:
                remember_servers(code, names)
                synced += 1
            # Progress counts attempts, so it always reaches the total.
            print(json.dumps({"progress": index + 1, "total": len(todo), "country": code}), flush=True)
            if index + 1 < len(todo):
                time.sleep(pace)
        return result(synced, failed, 0)
    except (OSError, RuntimeError, ValueError) as exc:
        return result(synced, failed, None, clean_command_error(exc))
    finally:
        os.close(lock)


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

    seen = set()
    candidates = [candidate for candidate in candidates if not (candidate in seen or seen.add(candidate))]
    return cc, [f"{candidate}.cg-dialup.net" for candidate in candidates[:MAX_NATIVE_CANDIDATES]]


def _probe_endpoint(host, port=1337, timeout=ENDPOINT_PROBE_TIMEOUT_SECONDS):
    """Return (host, seconds) when the WireGuard API port accepts TCP, else (host, None)."""
    started = time.monotonic()
    try:
        address = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)[0][4]
        with socket.create_connection(address[:2], timeout=timeout):
            pass
    except OSError:
        return host, None
    return host, time.monotonic() - started


def reachable_endpoints(hosts, budget=ENDPOINT_PROBE_BUDGET_SECONDS, grace=ENDPOINT_PROBE_GRACE_SECONDS):
    """Probe hosts in parallel within a hard budget; reachable ones, fastest first.

    No credentials are sent: this is DNS plus a TCP connect to port 1337. Once
    the first host answers, slower ones get only `grace` seconds more (None
    waits for the whole budget), so dead racks never stall a connect.
    """
    if not hosts:
        return []
    deadline = time.monotonic() + budget
    first_answer_at = None
    answered = []
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=min(16, len(hosts)))
    try:
        pending = {executor.submit(_probe_endpoint, host) for host in hosts}
        while pending and len(answered) < MAX_NATIVE_CANDIDATES:
            limit = deadline
            if first_answer_at is not None and grace is not None:
                limit = min(deadline, first_answer_at + grace)
            remaining = limit - time.monotonic()
            if remaining <= 0:
                break
            done, pending = concurrent.futures.wait(
                pending, timeout=remaining, return_when=concurrent.futures.FIRST_COMPLETED
            )
            for future in done:
                host, latency = future.result()
                if latency is not None:
                    answered.append((host, latency))
                    if first_answer_at is None:
                        first_answer_at = time.monotonic()
    finally:
        # Never wait on a stuck resolver beyond the budget.
        executor.shutdown(wait=False, cancel_futures=True)
    return [host for host, _ in sorted(answered, key=lambda item: item[1])]


def probe_servers(country_codes, session=None):
    """Reachability report per country, for diagnostics.

    The probe itself sends no credentials. With a usable session it also lists
    what CyberGhost's own server API returns, to compare the two.
    """
    report = {}
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
                    "Authentication failed. Please verify your CyberGhost subscription or run 'cyberghostvpn --setup'."
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
            err += " Install or configure the official cyberghostvpn CLI; its current server inventory is supported."
        raise RuntimeError(err)
    return addkey_data, connected_host


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


# ==============================================================================
# WireGuard keys (RFC 7748 X25519, no wireguard-tools dependency)
# ==============================================================================

_X25519_P = 2**255 - 19
_X25519_A24 = 121665
_X25519_BASE = (9).to_bytes(32, "little")


def _x25519_clamp(scalar):
    clamped = bytearray(scalar)
    clamped[0] &= 248
    clamped[31] &= 127
    clamped[31] |= 64
    return bytes(clamped)


def x25519(scalar, u_point):
    """RFC 7748 section 5 Montgomery ladder over Curve25519."""
    if len(scalar) != 32 or len(u_point) != 32:
        raise ValueError("X25519 inputs must be 32 bytes")
    p = _X25519_P
    k = int.from_bytes(_x25519_clamp(scalar), "little")
    x1 = int.from_bytes(u_point, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for bit in reversed(range(255)):
        k_bit = (k >> bit) & 1
        swap ^= k_bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = k_bit
        a = (x2 + z2) % p
        aa = a * a % p
        b = (x2 - z2) % p
        bb = b * b % p
        e = (aa - bb) % p
        c = (x3 + z3) % p
        d = (x3 - z3) % p
        da = d * a % p
        cb = c * b % p
        x3 = (da + cb) ** 2 % p
        z3 = x1 * (da - cb) ** 2 % p
        x2 = aa * bb % p
        z2 = e * (aa + _X25519_A24 * e) % p
    if swap:
        x2, x3, z2, z3 = x3, x2, z3, z2
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


def generate_wireguard_keys():
    """Return a fresh (private, public) WireGuard key pair as base64 strings."""
    private = _x25519_clamp(os.urandom(32))
    public = x25519(private, _X25519_BASE)
    priv = validate_wireguard_key(base64.b64encode(private).decode("ascii"))
    pub = validate_wireguard_key(base64.b64encode(public).decode("ascii"))
    return priv, pub


# ==============================================================================
# NetworkManager tunnel lifecycle (unprivileged; NM authorizes through Polkit)
# ==============================================================================


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


def legacy_tunnel_active(ip_binary):
    """The interface exists but is not our NetworkManager connection."""
    return _interface_state(ip_binary) is True and nm_active_state() == ""


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
    except (OSError, subprocess.TimeoutExpired, RuntimeError) as exc:
        problems = nm_remove_profile(ip_binary)
        message = clean_command_error(exc, "WireGuard activation failed")
        if problems:
            message += f"; rollback incomplete: {'; '.join(problems)}"
        raise RuntimeError(message) from exc


def connect(country_code="PT", server_type="traffic", city=None, config_path=None, server=None):
    """Negotiate a CyberGhost peer and activate it as a NetworkManager connection."""
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
    was_up = nm_active_state() != ""
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
    state = nm_active_state()
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


def build_login_payload(username, password):
    return {"userName": username, "password": password}


def build_device_payload(machine_name):
    return {"data": {"linuxApp": True, "machineName": machine_name}}


def api_request(
    method, path, payload=None, jwt=None, budget=ACCOUNT_API_BUDGET_SECONDS, max_bytes=MAX_HTTP_RESPONSE_BYTES
):
    """Authenticated JSON request against the CyberGhost account API."""
    requests = load_requests()
    deadline = time.monotonic() + budget
    headers = {
        "Content-Type": "application/json",
        "x-app-key": api_app_key(),
        "User-Agent": USER_AGENT,
    }
    if jwt:
        headers["Authorization"] = f"Bearer {validate_api_credential(jwt, 'session token')}"
    session = requests.Session()
    session.trust_env = False
    try:
        response = session.request(
            method,
            API_BASE + path,
            json=payload,
            headers=headers,
            timeout=(min(5, budget), min(12, budget)),
            verify=True,
            allow_redirects=False,
            stream=True,
        )
        response._cyberghost_body = read_response_bounded(response, max_bytes=max_bytes, deadline=deadline)
        return response
    finally:
        session.close()


def write_user_config(path, username, device_name, device, session=None):
    safe_username = validate_config_text(username, "username", 256)
    safe_device_name = validate_config_text(str(device.get("name") or device_name), "device name", 64)
    token = validate_api_credential(str(device.get("token") or ""), "device token")
    secret = validate_api_credential(str(device.get("tokenSecret") or device.get("secret") or ""), "device secret")
    cfg = configparser.ConfigParser(interpolation=None)
    # Keep only the account identifier and device credentials. The account
    # password is used for registration and is deliberately never persisted.
    cfg["account"] = {"username": safe_username}
    cfg["device"] = {
        "name": safe_device_name,
        "token": token,
        # The API returns the secret as `tokenSecret`; the CLI stores it as `secret`.
        "secret": secret,
    }
    # The login session token reads CyberGhost's live server list, which the
    # device token cannot. It expires on its own; the password is never kept.
    if session and session.get("jwt"):
        cfg["session"] = {"jwt": validate_api_credential(str(session["jwt"]), "session token")}
        user_id = str(session.get("user_id") or "")
        if user_id.isdigit() and len(user_id) <= 20:
            cfg["session"]["user_id"] = user_id
    target_dir = os.path.dirname(os.path.abspath(path))
    os.makedirs(target_dir, mode=0o700, exist_ok=True)
    os.chmod(target_dir, 0o700)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", dir=target_dir, delete=False, prefix=".config_ini_", encoding="utf-8"
        ) as tf:
            os.chmod(tf.name, 0o600)
            temp_name = tf.name
            cfg.write(tf)
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass


def register(config_path=None):
    """Link a CyberGhost account natively — no cyberghostvpn CLI required.

    Credentials come from CG_USERNAME/CG_PASSWORD (used by the GUI so they
    never appear in argv) or from interactive prompts. The env vars are
    popped immediately so they never outlive this call — register() is the
    only path that should ever see them, and a child subprocess started
    later must not inherit them by accident.
    """
    import getpass

    # Pop the credentials from os.environ before any other code can read
    # them. A caller (the GUI's panel) sets them only for this call; if we
    # left them in os.environ, a later subprocess.Popen would inherit them
    # by default and an exception traceback captured for the panel could
    # echo them back. Clearing here keeps the secret in local variables.
    env_username = os.environ.pop("CG_USERNAME", "")
    env_password = os.environ.pop("CG_PASSWORD", "")
    try:
        target = validate_user_config_path(config_path)
        if os.path.basename(target) == "config.ini":
            raise RuntimeError(
                "Native registration cannot overwrite the vendor CLI config. Use ~/.cyberghost/native.ini."
            )
        username = env_username.strip()[:256]
        password = env_password[:256]
        if not username or not password:
            try:
                if not sys.stdin.isatty():
                    credentials_line = sys.stdin.readline(4096)
                    if credentials_line:
                        credentials = json.loads(credentials_line)
                        username = username or str(credentials.get("username", "")).strip()[:256]
                        password = password or str(credentials.get("password", ""))[:256]
            except (OSError, UnicodeError, json.JSONDecodeError, AttributeError):
                pass
        if not username or not password:
            username = username or input("CyberGhost username: ").strip()[:256]
            password = password or getpass.getpass("CyberGhost password: ")[:256]
        if not username or not password:
            raise RuntimeError("Username and password are required.")
        device_name = (os.environ.get("CG_DEVICE_NAME") or socket.gethostname() or "linux-app").strip()[
            :64
        ] or "linux-app"

        print("Authenticating ...")
        res = api_request("POST", "/my/account/jwt?language=en", build_login_payload(username, password))
        if res.status_code != 200:
            raise RuntimeError(
                f"Authentication failed (HTTP {res.status_code}). Check your CyberGhost account credentials."
            )
        jwt = response_json(res).get("jwt")
        if not jwt:
            raise RuntimeError("Authentication response did not contain a session token.")

        print(f"Registering device '{device_name}' ...")
        res = api_request("POST", "/my/devices", build_device_payload(device_name), jwt=jwt)
        if res.status_code != 201:
            detail = ""
            try:
                body = response_json(res)
                detail = str(body.get("errorMessage") or body.get("errorCode") or "")[:256]
            except (RuntimeError, TypeError, ValueError, UnicodeError):
                pass
            raise RuntimeError(f"Device registration failed (HTTP {res.status_code}). {detail}".strip())
        device = response_json(res)
        if not device.get("token"):
            raise RuntimeError("Device registration response missing token.")

        session = {"jwt": jwt, "user_id": account_user_id(jwt)}
        write_user_config(target, username, device_name, device, session=session)
        print(f"Account linked. Device credentials stored in {target}")
    finally:
        # Defense in depth: drop the local copies and re-clear the env vars
        # in case any inner code path re-set them while we were running.
        username = None
        password = None
        env_username = None
        env_password = None
        os.environ.pop("CG_USERNAME", None)
        os.environ.pop("CG_PASSWORD", None)


def cli_account_configured():
    """Local prerequisite check only; this does not prove vendor authentication."""
    path = legacy_config_path()
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_CONFIG_BYTES or info.st_mode & 0o077:
            return False
        if info.st_uid != invoking_user().pw_uid:
            return False
        with os.fdopen(fd, encoding="utf-8") as stream:
            fd = None
            config = configparser.ConfigParser(interpolation=None)
            config.read_string(stream.read(MAX_CONFIG_BYTES + 1))
        return all(config.get("account", key, fallback="").strip() for key in ("username", "password"))
    except (OSError, UnicodeError, configparser.Error):
        return False
    finally:
        if fd is not None:
            os.close(fd)


def check():
    """Report onboarding readiness as JSON (fast, no heavy imports)."""
    result = {
        "nm": nm_available(),
        "nm_permission": nm_permission(),
        "requests": importlib.util.find_spec("requests") is not None,
        "cli": system_binary_available("cyberghostvpn"),
        "cli_configured": cli_account_configured(),
        "credentials": False,
        # Display only; privacy mode masks it in the panel.
        "account": "",
        "account_source": "",
        # "live": CyberGhost's own server list is used; "probe": fallback.
        "server_list": "",
        # Pre-1.7 installs placed a root helper and an optional Polkit rule.
        # They are no longer used and can be removed from the setup panel.
        "legacy_helper": secure_system_file(LEGACY_HELPER_PATH, executable=True),
        "legacy_polkit_rule": secure_system_file(LEGACY_POLKIT_RULE_PATH) or user_polkit_marker_installed(),
        "plugin_version": PLUGIN_VERSION,
    }
    try:
        account = load_account(None)
        result.update(credentials=True, account=account["username"], account_source=account["source"])
        result["server_list"] = "live" if session_usable(account["jwt"]) else "probe"
    except (OSError, RuntimeError, configparser.Error):
        pass
    print(json.dumps(result))


def secure_system_file(path, executable=False):
    """Recognize only a regular, root-owned file that others cannot modify."""
    try:
        file_stat = os.lstat(path)
    except OSError:
        return False
    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_uid != 0 or file_stat.st_mode & 0o022:
        return False
    return not executable or bool(file_stat.st_mode & 0o111)


def user_polkit_marker_installed():
    """Read the pre-1.7 installer marker when the system rule is not traversable."""
    path = os.path.join(invoking_user().pw_dir, LEGACY_POLKIT_MARKER_RELATIVE_PATH)
    try:
        marker_stat = os.lstat(path)
        if not stat.S_ISREG(marker_stat.st_mode) or marker_stat.st_uid != os.getuid():
            return False
        with open(path, encoding="ascii") as marker:
            return marker.read(128).strip() == LEGACY_POLKIT_MARKER_CONTENT
    except (OSError, UnicodeError):
        return False


def system_binary(name):
    path = shutil.which(name)
    if not path:
        raise FileNotFoundError(name)
    return path


def system_binary_available(name):
    try:
        system_binary(name)
        return True
    except (FileNotFoundError, RuntimeError):
        return False


def validate_request(args):
    """Reduce the release interface to native WireGuard traffic connections."""
    if args.action == "connect" and (
        args.protocol != "wireguard" or args.server_type != "traffic" or args.streaming_service
    ):
        raise RuntimeError("This release supports native WireGuard traffic connections only")
    if args.action != "connect" and (args.server or args.streaming_service):
        raise RuntimeError("Server and streaming selection are only valid for connect")
    return args


def main():
    parser = argparse.ArgumentParser(description="CyberGhost WireGuard Controller")
    parser.add_argument(
        "action",
        choices=[
            "sync-servers",
            "connect",
            "disconnect",
            "logout",
            "status",
            "check",
            "register",
            "servers",
            "streaming-services",
            "probe",
        ],
        help="Action to perform",
    )
    parser.add_argument("--country", "-c", default="PT", help="Country code (e.g. PT, ES, US, DE)")
    parser.add_argument("--server-type", "-t", default="traffic", choices=["traffic", "streaming", "torrent"])
    parser.add_argument("--protocol", default="wireguard", choices=["wireguard", "openvpn", "openvpn_tcp"])
    parser.add_argument("--city", help="Optional city name")
    parser.add_argument("--server", help="Exact CyberGhost server instance from the live inventory")
    parser.add_argument("--streaming-service", help="Streaming profile name reported by cyberghostvpn")
    parser.add_argument("--config", help="Explicit path to ~/.cyberghost/native.ini")
    parser.add_argument("--json", action="store_true", help="Output status or action result as JSON")
    parser.add_argument("--all", action="store_true", help="probe: check every supported country")

    args = None
    try:
        args = parser.parse_args()
        args = validate_request(args)
        if args.action in ACTIONS:

            def run_action():
                if args.action == "connect":
                    return connect(args.country, args.server_type, args.city, args.config, args.server)
                if args.action == "logout":
                    return logout()
                return disconnect()

            if args.json:
                with contextlib.redirect_stdout(io.StringIO()):
                    action_result = run_action()
                result = {"ok": True, "action": args.action}
                if isinstance(action_result, dict):
                    result.update(action_result)
                print(json.dumps(result))
            else:
                run_action()
        elif args.action == "status":
            status(args.json)
        elif args.action == "check":
            check()
        elif args.action == "register":
            register(args.config)
        elif args.action == "servers":
            print(json.dumps(get_servers_for_country(args.country, args.server_type)))
        elif args.action == "streaming-services":
            print(json.dumps(get_streaming_services(args.country)))
        elif args.action == "sync-servers":
            print(json.dumps(sync_servers()))
        elif args.action == "probe":
            codes = sorted(code for code in CITY_MAP if code != "UK") if args.all else [args.country]
            try:
                session = load_account(args.config)
            except (OSError, RuntimeError, configparser.Error):
                session = None
            report = probe_servers(codes, session)
            if args.json:
                print(json.dumps(report))
            else:
                for code, entry in report.items():
                    hosts = entry["reachable"]
                    state = f"{len(hosts)} reachable, fastest {hosts[0]}" if hosts else "NO REACHABLE SERVERS"
                    if entry.get("no_wireguard"):
                        state = "no WireGuard servers listed by CyberGhost"
                    else:
                        state += f" ({entry['known']} known)" if entry.get("known") else " (guessed pool)"
                    if "live" in entry:
                        live = entry["live"]
                        state += f" | live API: {len(live)} servers" + (f", lowest load {live[0]}" if live else "")
                    print(f"{code}  {entry['city'] or '-':<14} {state}")
    except Exception as e:
        if args is not None and args.json and args.action in ACTIONS:
            print(
                json.dumps(
                    {
                        "ok": False,
                        "action": args.action,
                        "error": clean_command_error(e),
                        "code": getattr(e, "code", ""),
                    }
                )
            )
        else:
            sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()

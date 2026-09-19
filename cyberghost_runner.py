#!/usr/bin/python3 -Es
"""
CyberGhost VPN WireGuard Native Backend & CLI
Directly negotiates WireGuard keys with CyberGhost dialup servers and manages wg-quick.
"""

import argparse
import base64
import binascii
import configparser
import contextlib
import fcntl
import importlib.util
import io
import ipaddress
import json
import os
import pwd
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
from urllib.parse import urlsplit, urlunsplit

WG_CONF_PATH = "/etc/wireguard/cyberghost.conf"
INTERFACE = "cyberghost"
HELPER_BIN_PATH = "/usr/local/bin/cyberghost-runner"
POLKIT_RULE_PATH = "/etc/polkit-1/rules.d/50-cyberghost.rules"
LIFECYCLE_LOCK_PATH = "/run/lock/cyberghost.lock"
_LIFECYCLE_LOCK_DEPTH = 0
_LIFECYCLE_LOCK_FD = None
POLKIT_MARKER_RELATIVE_PATH = os.path.join(".local", "state", "cyberghost", "polkit-rule-installed")
POLKIT_MARKER_CONTENT = "cyberghost-polkit-rule-v1"
PLUGIN_VERSION = "1.6.3"
HELPER_CAPABILITY_VERSION = "8"
MAX_CONFIG_BYTES = 64 * 1024
MAX_HELPER_BYTES = 256 * 1024
MAX_HTTP_RESPONSE_BYTES = 64 * 1024
MAX_SUBPROCESS_INPUT_BYTES = 64 * 1024
MAX_SUBPROCESS_OUTPUT_BYTES = 64 * 1024
NATIVE_CONNECT_BUDGET_SECONDS = 120
ACCOUNT_API_BUDGET_SECONDS = 30
MAX_NATIVE_CANDIDATES = 12
HELPER_ACTIONS = {"connect", "disconnect"}

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

# The vendor's city spelling and its dialup hostname prefix are not always the
# same. Keep CITY_MAP suitable for CLI inventory queries, and override only the
# endpoint prefix where the live inventory differs (Ukraine currently returns
# kiev-s401-iNN hosts for the city displayed as Kyiv).
DIALUP_CITY_MAP = {**CITY_MAP, "UA": "kiev"}

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

        return subprocess.CompletedProcess(
            argv,
            process.wait(),
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


def cli_connection_state():
    """Return the vendor's observed state, or None when its probe is inconclusive.

    This is process/tunnel presence, not proof of routing or leak protection.
    Unknown output must never count as successful activation or cleanup.
    """
    try:
        result = run_bounded(
            [system_binary("cyberghostvpn"), "--status"],
            timeout=3,
            max_output_bytes=8 * 1024,
            env=cyberghost_cli_environment(),
        )
    except (OSError, subprocess.TimeoutExpired, RuntimeError):
        return None
    if result.returncode != 0:
        return None
    output = (result.stdout or "").strip()
    if re.search(r"^No VPN connections? found\.?$", output, re.I | re.M):
        return False
    if re.search(r"^VPN connection found\.?$", output, re.I | re.M):
        return True
    return None


def stop_cli_connection():
    result = run_bounded(
        [system_binary("cyberghostvpn"), "--stop"],
        timeout=20,
        max_output_bytes=16 * 1024,
        env=cyberghost_cli_environment(),
    )
    if result.returncode != 0:
        raise RuntimeError(clean_command_error(result.stderr or result.stdout, "Vendor stop command failed"))
    if cli_connection_state() is not False:
        raise RuntimeError("Could not confirm that the vendor VPN stopped")


def connect_via_cli(country_code, server_type, protocol, streaming_service=None):
    """Delegate optional modes, then verify activation instead of trusting exit zero."""
    cc = validate_country_code(country_code)
    context = f"{cc} via {protocol} / {server_type}"
    if server_type == "streaming" and streaming_service:
        context += f" ({streaming_service})"

    # Validate before entering the activation/rollback boundary.
    cmd = [system_binary("cyberghostvpn")]
    if server_type == "torrent":
        cmd.append("--torrent")
    elif server_type == "streaming":
        cmd += ["--streaming", validate_streaming_service(streaming_service)]
    else:
        cmd.append("--traffic")
    if protocol == "wireguard":
        cmd.append("--wireguard")
    else:
        cmd += ["--openvpn", "--connection", "tcp" if protocol == "openvpn_tcp" else "udp"]
    cmd += ["--country-code", cc, "--connect"]

    print(f"Connecting to {cc} ({protocol} / {server_type}) via cyberghostvpn CLI...")
    try:
        result = run_bounded(cmd, timeout=120, max_output_bytes=16 * 1024, env=cyberghost_cli_environment())
        if result.returncode != 0:
            raise RuntimeError(
                clean_command_error(
                    result.stdout or result.stderr,
                    f"cyberghostvpn connect to {context} failed (exit {result.returncode})",
                )
            )
        # The vendor can exit zero even when its daemon fails. Allow a short,
        # bounded startup grace period; never infer success from connect text.
        for attempt in range(3):
            if cli_connection_state() is True:
                break
            if attempt < 2:
                time.sleep(0.5)
        else:
            raise RuntimeError(f"cyberghostvpn reported success for {context}, but no active VPN could be verified")
    except FileNotFoundError as exc:
        raise RuntimeError("'cyberghostvpn' CLI is not installed. Install it or use WireGuard traffic mode.") from exc
    except (OSError, subprocess.TimeoutExpired, RuntimeError) as exc:
        message = (
            f"cyberghostvpn connect to {context} timed out."
            if isinstance(exc, subprocess.TimeoutExpired)
            else clean_command_error(exc)
        )
        try:
            stop_cli_connection()
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as cleanup_error:
            message += f" Cleanup failed: {clean_command_error(cleanup_error)}"
        raise RuntimeError(message) from exc

    print(f"Vendor VPN active for {cc} via {protocol} ({server_type}).")
    return {"backend": "cyberghostvpn", "country": cc, "protocol": protocol, "server_type": server_type}


def find_config_path(override_path=None):
    if override_path:
        return os.path.abspath(os.path.expanduser(override_path))

    if os.geteuid() != 0:
        env_override = os.environ.get("CYBERGHOST_CONFIG")
        if env_override:
            return os.path.abspath(os.path.expanduser(env_override))

    return user_config_path()


def invoking_user():
    """Return the user who initiated pkexec, not root's environment user."""
    if os.geteuid() == 0:
        raw_uid = os.environ.get("PKEXEC_UID", "")
        if raw_uid.isdigit():
            try:
                return pwd.getpwuid(int(raw_uid))
            except KeyError:
                pass
    try:
        return pwd.getpwuid(os.getuid())
    except KeyError:
        return pwd.getpwnam(os.environ.get("USER") or "root")


def cyberghost_cli_environment():
    """Select the initiating user's vendor configuration under pkexec.

    CLI 1.4.1 constructs /home/<SUDO_USER or USER>/.cyberghost, ignoring
    HOME. Set USER from the verified invoking uid and do not inherit
    SUDO_USER. Keep HOME correct for dependencies and other CLI versions.
    The vendor's hard-coded /home layout needs separate compatibility work
    for accounts with nonstandard home directories.
    """
    if os.geteuid() != 0 or not os.environ.get("PKEXEC_UID", "").isdigit():
        return None

    user = invoking_user()
    # Use an allowlist rather than inheriting the caller's environment. The
    # vendor CLI needs the user's HOME to find its account config, but must not
    # receive interpreter hooks, dynamic-loader overrides, XDG redirects or
    # shell startup files while it is running as root.
    env = {
        "HOME": user.pw_dir,
        "USER": user.pw_name,
        "LOGNAME": user.pw_name,
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    }
    for variable in ("LANG", "LC_ALL", "LC_CTYPE", "TERM"):
        if variable in os.environ:
            env[variable] = os.environ[variable]
    return env


def user_config_path():
    return os.path.join(invoking_user().pw_dir, ".cyberghost", "native.ini")


def legacy_config_path():
    return os.path.join(invoking_user().pw_dir, ".cyberghost", "config.ini")


def validate_user_config_path(path, require_default=False):
    """Keep account state inside the invoking user's private CyberGhost directory."""
    expected = os.path.abspath(user_config_path())
    candidate = os.path.abspath(os.path.expanduser(path or expected))
    if require_default and candidate not in (expected, os.path.abspath(legacy_config_path())):
        raise RuntimeError("Root helper may only use the invoking user's CyberGhost config")
    if os.path.commonpath((candidate, os.path.dirname(expected))) != os.path.dirname(expected):
        raise RuntimeError("Configuration path must stay inside ~/.cyberghost")
    if os.path.basename(candidate) not in ("native.ini", "config.ini"):
        raise RuntimeError("Configuration path must be ~/.cyberghost/native.ini or the legacy config.ini")
    config_dir = os.path.dirname(candidate)
    if os.path.lexists(config_dir) and os.path.islink(config_dir):
        raise RuntimeError("CyberGhost config directory must not be a symlink")
    return candidate


def get_credentials(config_path=None):
    path = find_config_path(config_path)
    # Read-only compatibility: never rewrite the vendor CLI's credentials.
    # A present but invalid native file must fail closed, not fall back.
    if path == user_config_path() and not os.path.lexists(path):
        path = legacy_config_path()
    if os.geteuid() == 0 and os.environ.get("PKEXEC_UID", "").isdigit():
        path = validate_user_config_path(path, require_default=True)
    if not os.path.exists(path):
        raise RuntimeError(
            f"Configuration file not found: {path}. Please link your account or run 'cyberghostvpn --setup' first."
        )
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
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
        if os.geteuid() == 0 and os.environ.get("PKEXEC_UID", "").isdigit():
            if file_stat.st_uid != invoking_user().pw_uid:
                raise RuntimeError("Configuration file must belong to the invoking user")

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
    return token, secret


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
            env=cyberghost_cli_environment(),
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
            env=cyberghost_cli_environment(),
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


def generate_wireguard_keys():
    try:
        wg_binary = system_binary("wg")
        priv_raw = run_bounded([wg_binary, "genkey"], timeout=5, max_output_bytes=256).stdout.strip()
        pub_raw = run_bounded(
            [wg_binary, "pubkey"], timeout=5, input_data=priv_raw.encode(), max_output_bytes=256
        ).stdout.strip()
        priv = validate_wireguard_key(priv_raw)
        pub = validate_wireguard_key(pub_raw)
        return priv, pub
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(
            f"Failed to generate WireGuard keys using 'wg': {e}. Ensure wireguard-tools is installed."
        ) from e


def build_wg_config(private_key, peer_ip, server_key, server_ip, server_port, dns_servers=None):
    """
    Render a wg-quick config that tunnels IPv4 AND IPv6 (no v6 leak).
    Validates all inputs strictly to eliminate directive and newline injection.
    """
    valid_priv = validate_wireguard_key(private_key)
    valid_peer_ip = validate_ip(peer_ip)
    valid_server_key = validate_wireguard_key(server_key)
    valid_server_host = validate_endpoint_host(server_ip)
    endpoint_host = f"[{valid_server_host}]" if ":" in valid_server_host else valid_server_host
    valid_server_port = validate_port(server_port)
    valid_dns = validate_dns_servers(dns_servers, require_nonempty=True)
    peer_prefix = "/128" if ":" in valid_peer_ip else "/32"

    lines = [
        "[Interface]",
        f"PrivateKey = {valid_priv}",
        f"Address = {valid_peer_ip}{peer_prefix}",
    ]
    if valid_dns:
        lines.append(f"DNS = {valid_dns}")
    lines += [
        "",
        "[Peer]",
        f"PublicKey = {valid_server_key}",
        "AllowedIPs = 0.0.0.0/0, ::/0",
        f"Endpoint = {endpoint_host}:{valid_server_port}",
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
    safe_text = str(text)[:256]
    for amount, unit in re.findall(r"(\d+)\s*(second|minute|hour|day)", safe_text, re.I):
        u = unit.lower().rstrip("s")
        if u in _HANDSHAKE_UNITS:
            total += int(amount) * _HANDSHAKE_UNITS[u]
            found = True
    return total if found else None


def parse_wg_show(output):
    """Extract endpoint / transfer / handshake age from `wg show <iface>` output."""
    info = {}
    safe_out = str(output)[:4096]
    for line in safe_out.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip().lower()
        value = value.strip()
        if key == "endpoint":
            info["endpoint"] = value[:64]
        elif key == "transfer":
            info["transfer"] = value[:64]
        elif key == "latest handshake":
            secs = parse_handshake_seconds(value)
            if secs is not None:
                info["handshake_sec"] = secs
    return info


def select_native_candidates(country_code, server_type="traffic", city=None, server=None):
    """Select validated, bounded native WireGuard endpoint candidates.

    The privileged fixed helper never invokes the optional vendor CLI. It uses
    the bounded static inventory (or an explicitly validated server selector),
    so root-side execution is limited to native WireGuard operations.
    """
    cc = validate_country_code(country_code)
    selected_server = validate_server_selector(server) if server else None
    use_cli_inventory = os.geteuid() != 0
    cli_servers = [] if city or not use_cli_inventory else get_servers_for_country(cc, server_type)

    if selected_server and use_cli_inventory:
        available_servers = {item["server"] for item in cli_servers}
        if selected_server not in available_servers:
            raise RuntimeError(
                f"Server '{selected_server}' is not available for {cc}. Refresh the server list and try again."
            )

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
    else:
        candidates = [
            f"{city_slug}-s{instance}-i{idx}" for instance in ("405", "401", "406", "407") for idx in ("01", "02", "03")
        ]

    seen = set()
    candidates = [candidate for candidate in candidates if not (candidate in seen or seen.add(candidate))]
    return cc, [f"{candidate}.cg-dialup.net" for candidate in candidates[:MAX_NATIVE_CANDIDATES]]


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


def secure_directory_path(path, create=False, mode=0o700):
    """Require a root-owned, non-writable directory ancestry for root paths."""
    normalized = os.path.abspath(path)
    if not normalized.startswith("/"):
        raise RuntimeError(f"System path must be absolute: {path}")

    current = "/"
    for component in normalized.strip("/").split("/"):
        if not component:
            continue
        current = os.path.join(current, component)
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            if not create or current != normalized:
                raise RuntimeError(f"Trusted system directory is missing: {current}") from None
            os.mkdir(current, mode)
            os.chmod(current, mode)
            info = os.lstat(current)
        except OSError as exc:
            raise RuntimeError(f"Could not inspect system directory {current}: {exc}") from exc
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise RuntimeError(f"System directory must not be a symlink or non-directory: {current}")
        if info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError(f"System directory is not trusted: {current}")
    return normalized


def secure_wireguard_config(path=None):
    """Validate the generated config before any privileged consumer reads it."""
    path = path or WG_CONF_PATH
    parent = os.path.dirname(os.path.abspath(path))
    if os.geteuid() == 0:
        try:
            secure_directory_path(parent)
        except RuntimeError:
            # The final /etc/wireguard directory is allowed to be absent on a
            # fresh host; write_wireguard_config creates only that directory.
            if os.path.lexists(parent):
                raise
            return False
    if not os.path.lexists(path):
        return False
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise RuntimeError(f"Could not inspect WireGuard config: {exc}") from exc
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise RuntimeError("WireGuard config must be a regular file, not a symlink")
    if os.geteuid() == 0 and (info.st_uid != 0 or info.st_mode & 0o077 or info.st_nlink != 1):
        raise RuntimeError("WireGuard config must be a private, single-link root-owned file")
    return True


@contextlib.contextmanager
def lifecycle_lock(timeout=30):
    """Serialize all root-side mutations of the single global tunnel."""
    global _LIFECYCLE_LOCK_DEPTH, _LIFECYCLE_LOCK_FD
    if os.geteuid() != 0:
        yield
        return

    if _LIFECYCLE_LOCK_DEPTH:
        _LIFECYCLE_LOCK_DEPTH += 1
        try:
            yield
        finally:
            _LIFECYCLE_LOCK_DEPTH -= 1
        return

    secure_directory_path(os.path.dirname(LIFECYCLE_LOCK_PATH))
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(LIFECYCLE_LOCK_PATH, flags, 0o600)
    except OSError as exc:
        raise RuntimeError(f"Could not open the CyberGhost lifecycle lock: {exc}") from exc

    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError("CyberGhost lifecycle lock is not a trusted root-owned file")
        os.fchmod(fd, 0o600)
        deadline = time.monotonic() + max(0.1, timeout)
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Another CyberGhost VPN operation is already in progress") from None
                time.sleep(0.1)
        _LIFECYCLE_LOCK_FD = fd
        _LIFECYCLE_LOCK_DEPTH = 1
        try:
            yield
        finally:
            _LIFECYCLE_LOCK_DEPTH = 0
            _LIFECYCLE_LOCK_FD = None
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


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


def verify_wireguard_cleanup(ip_binary, resolver_binary=None, require_resolver=False):
    """Verify the side effects that wg-quick is responsible for removing."""
    problems = []
    if not ip_binary:
        problems.append("ip is unavailable, so interface and route cleanup cannot be verified")
        return problems

    interface_state = _interface_state(ip_binary)
    if interface_state is None:
        problems.append("WireGuard interface state could not be verified")
    elif interface_state:
        problems.append(f"interface {INTERFACE} is still present")

    try:
        route_result = run_bounded([ip_binary, "route", "show", "table", "51820"], timeout=5, max_output_bytes=8 * 1024)
        route_detail = f"{route_result.stdout or ''}\n{route_result.stderr or ''}"
        # iproute2 returns exit 2 when a policy table has never been created or
        # has already been removed. That is positive evidence of an empty table,
        # not an unverifiable cleanup failure.
        route_table_absent = route_result.returncode == 2 and re.search(
            r"FIB table does not exist|table .* does not exist", route_detail, re.I
        )
        if route_result.returncode != 0 and not route_table_absent:
            problems.append("WireGuard policy route table could not be verified")
        elif route_result.returncode == 0 and (route_result.stdout or "").strip():
            problems.append("WireGuard policy routes remain in table 51820")

        rule_result = run_bounded([ip_binary, "rule", "show"], timeout=5, max_output_bytes=8 * 1024)
        if rule_result.returncode != 0:
            problems.append("WireGuard policy rules could not be verified")
        elif re.search(r"(?:lookup|fwmark)\s+51820\b", rule_result.stdout or ""):
            problems.append("WireGuard policy rules remain")
    except (OSError, subprocess.TimeoutExpired, RuntimeError):
        problems.append("WireGuard routing state could not be verified")

    if resolver_binary:
        try:
            resolver_result = run_bounded([resolver_binary, "-l", INTERFACE], timeout=5, max_output_bytes=8 * 1024)
            if resolver_result.returncode == 0 and (resolver_result.stdout or "").strip():
                problems.append("VPN resolver state remains registered")
            elif resolver_result.returncode not in (0, 1):
                problems.append("VPN resolver state could not be verified")
        except (OSError, subprocess.TimeoutExpired, RuntimeError):
            problems.append("VPN resolver state could not be verified")
    elif require_resolver:
        problems.append("resolvconf is unavailable, so VPN DNS cleanup cannot be verified")

    return problems


def cleanup_wireguard_state(wg_quick, ip_binary, config_present=False):
    """Tear down the tunnel and return only verified residual-state errors."""
    initial_state = _interface_state(ip_binary) if ip_binary else None
    try:
        resolver_binary = system_binary("resolvconf")
    except (FileNotFoundError, RuntimeError):
        resolver_binary = None
    require_resolver = config_present or initial_state is True

    if wg_quick:
        try:
            down_result = run_bounded([wg_quick, "down", INTERFACE], timeout=20, max_output_bytes=8 * 1024)
        except (OSError, subprocess.TimeoutExpired, RuntimeError):
            down_result = None
    else:
        down_result = None

    if ip_binary:
        try:
            delete_result = run_bounded(
                [ip_binary, "link", "delete", "dev", INTERFACE], timeout=10, max_output_bytes=8 * 1024
            )
        except (OSError, subprocess.TimeoutExpired, RuntimeError):
            delete_result = None
    else:
        delete_result = None

    problems = verify_wireguard_cleanup(ip_binary, resolver_binary, require_resolver)
    # wg-quick and `ip link delete` commonly return non-zero for an already
    # absent interface. Verified absence makes those benign; unknown state does not.
    if problems:
        if down_result is None:
            problems.insert(0, "wg-quick down could not be completed")
        elif down_result.returncode != 0:
            problems.insert(0, clean_command_error(down_result.stderr or down_result.stdout, "wg-quick down failed"))
        if delete_result is None:
            problems.insert(0, "interface deletion could not be completed")
        elif delete_result.returncode != 0 and initial_state is True:
            problems.insert(
                0, clean_command_error(delete_result.stderr or delete_result.stdout, "interface deletion failed")
            )
    return problems


def remove_wireguard_config():
    if not os.path.lexists(WG_CONF_PATH):
        return
    secure_wireguard_config()
    try:
        os.unlink(WG_CONF_PATH)
    except OSError as exc:
        raise RuntimeError(f"Could not remove WireGuard config: {exc}") from exc
    if os.path.lexists(WG_CONF_PATH):
        raise RuntimeError("WireGuard config remained after removal")


def write_wireguard_config(private_key, peer_ip, server_key, server_ip, server_port, dns_servers=None):
    """Atomically write a validated, trusted WireGuard configuration."""
    cfg = build_wg_config(
        private_key,
        peer_ip,
        server_key,
        server_ip,
        server_port,
        dns_servers=validate_dns_servers(dns_servers, require_nonempty=True),
    )
    conf_dir = os.path.dirname(WG_CONF_PATH)
    if os.geteuid() == 0:
        secure_directory_path(conf_dir, create=True, mode=0o700)
    else:
        os.makedirs(conf_dir, exist_ok=True)
    if os.path.lexists(WG_CONF_PATH):
        secure_wireguard_config()
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile("w", dir=conf_dir, delete=False, prefix=".cyberghost_conf_") as tf:
            os.chmod(tf.name, 0o600)
            temp_name = tf.name
            tf.write(cfg)
            tf.flush()
            os.fsync(tf.fileno())
        os.replace(temp_name, WG_CONF_PATH)
        temp_name = None
        if os.geteuid() == 0:
            secure_wireguard_config()
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass


def best_effort_wireguard_down(wg_quick, timeout=5):
    """Remove a partially-created interface without masking the original error."""
    try:
        run_bounded([wg_quick, "down", INTERFACE], timeout=timeout, max_output_bytes=8 * 1024)
    except (OSError, subprocess.TimeoutExpired, RuntimeError):
        pass


def activate_wireguard(wg_quick, deadline):
    """Activate once; every failure after launch attempts rollback, never drops DNS."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("WireGuard connection attempt timed out before tunnel activation")
    try:
        result = run_bounded([wg_quick, "up", INTERFACE], timeout=min(45, remaining), max_output_bytes=16 * 1024)
        if result.returncode != 0:
            detail = clean_command_error(result.stderr or result.stdout, "unknown error")
            if "resolv" in detail.lower():
                raise RuntimeError(
                    "VPN DNS setup failed. Configure a working resolvconf provider (for example openresolv), "
                    "then reconnect. The tunnel was not activated without VPN DNS."
                )
            raise RuntimeError(f"wg-quick up failed: {detail}")
    except (OSError, subprocess.TimeoutExpired, RuntimeError):
        best_effort_wireguard_down(wg_quick)
        raise


def connect(country_code="PT", server_type="traffic", city=None, config_path=None, server=None):
    """Serialize the complete native transaction, including key exchange."""
    with lifecycle_lock(timeout=NATIVE_CONNECT_BUDGET_SECONDS):
        return _connect_impl(country_code, server_type, city, config_path, server)


def _connect_impl(country_code="PT", server_type="traffic", city=None, config_path=None, server=None):
    """Establish a native WireGuard tunnel within one bounded operation budget."""
    deadline = time.monotonic() + NATIVE_CONNECT_BUDGET_SECONDS
    token, secret = get_credentials(config_path)
    priv_key, pub_key = generate_wireguard_keys()

    cc, candidates = select_native_candidates(country_code, server_type, city, server)
    addkey_data, connected_host = exchange_wireguard_key(candidates, pub_key, token, secret, cc, deadline)

    # A missing field gets the documented compatibility defaults. An explicit
    # empty field is invalid: never activate without a VPN DNS configuration.
    if "dns_servers" in addkey_data:
        raw_dns = addkey_data["dns_servers"]
    else:
        raw_dns = ["10.0.0.243", "10.0.0.242", "1.1.1.1"]
    dns_servers_str = validate_dns_servers(raw_dns, require_nonempty=True)
    raw_server_ip = addkey_data.get("server_ip") or connected_host
    server_ip = validate_endpoint_host(raw_server_ip)
    server_port = validate_port(addkey_data.get("server_port", 1337))
    peer_ip = validate_ip(addkey_data.get("peer_ip", ""))
    server_key = validate_wireguard_key(addkey_data.get("server_key", ""))

    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("WireGuard connection attempt timed out before tunnel setup")

    with lifecycle_lock(timeout=min(30, remaining)):
        config_present = secure_wireguard_config()
        try:
            ip_binary = system_binary("ip")
            wg_quick = system_binary("wg-quick")
        except (FileNotFoundError, RuntimeError) as exc:
            raise RuntimeError(f"WireGuard lifecycle tools are unavailable: {clean_command_error(exc)}") from exc

        cleanup_problems = cleanup_wireguard_state(wg_quick, ip_binary, config_present)
        if cleanup_problems:
            raise RuntimeError("Cannot safely replace the existing WireGuard state: " + "; ".join(cleanup_problems))

        write_wireguard_config(priv_key, peer_ip, server_key, server_ip, server_port, dns_servers_str)
        try:
            activate_wireguard(wg_quick, deadline)
            if _interface_state(ip_binary) is not True:
                raise RuntimeError("wg-quick reported success but the CyberGhost interface is not present")
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as exc:
            rollback_problems = cleanup_wireguard_state(wg_quick, ip_binary, True)
            if rollback_problems:
                raise RuntimeError(
                    f"{clean_command_error(exc, 'WireGuard activation failed')}; "
                    f"rollback incomplete: {'; '.join(rollback_problems)}"
                ) from exc
            try:
                remove_wireguard_config()
            except RuntimeError as remove_error:
                raise RuntimeError(
                    f"{clean_command_error(exc, 'WireGuard activation failed')}; "
                    f"rollback completed but config cleanup failed: {remove_error}"
                ) from exc
            raise

    print("VPN connection established.")
    print(f"Connected to {cc} via {connected_host} (IP: {server_ip})")
    return {
        "backend": "wireguard",
        "country": cc,
        "server": connected_host,
        "server_ip": server_ip,
        "protocol": "wireguard",
        "server_type": server_type,
    }


def disconnect():
    with lifecycle_lock(timeout=30):
        try:
            ip_binary = system_binary("ip")
            wg_quick = system_binary("wg-quick")
        except (FileNotFoundError, RuntimeError) as exc:
            raise RuntimeError(f"WireGuard lifecycle tools are unavailable: {clean_command_error(exc)}") from exc

        config_present = secure_wireguard_config()
        was_up = _interface_state(ip_binary) is True
        cleanup_problems = cleanup_wireguard_state(wg_quick, ip_binary, config_present)
        if cleanup_problems:
            raise RuntimeError("Could not verify WireGuard cleanup: " + "; ".join(cleanup_problems))
        remove_wireguard_config()

    if was_up:
        print("VPN connection terminated.")
    else:
        print("No VPN connections found.")
    return {"backend": "wireguard", "connected": False}


def build_login_payload(username, password):
    return {"userName": username, "password": password}


def build_device_payload(machine_name):
    return {"data": {"linuxApp": True, "machineName": machine_name}}


def api_request(method, path, payload=None, jwt=None):
    """Authenticated JSON request against the CyberGhost account API."""
    requests = load_requests()
    deadline = time.monotonic() + ACCOUNT_API_BUDGET_SECONDS
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
            timeout=(5, min(12, ACCOUNT_API_BUDGET_SECONDS)),
            verify=True,
            allow_redirects=False,
            stream=True,
        )
        response._cyberghost_body = read_response_bounded(response, deadline=deadline)
        return response
    finally:
        session.close()


def write_user_config(path, username, device_name, device):
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

        write_user_config(target, username, device_name, device)
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
        "wg_tools": shutil.which("wg-quick") is not None,
        "dns_tools": shutil.which("resolvconf") is not None,
        "requests": importlib.util.find_spec("requests") is not None,
        "cli": system_binary_available("cyberghostvpn"),
        "cli_configured": cli_account_configured(),
        "credentials": False,
        "helper_installed": secure_helper_installed(),
        "helper_present": secure_helper_present(),
        "helper_version": installed_helper_version(),
        "plugin_version": PLUGIN_VERSION,
        # /etc/polkit-1/rules.d is commonly root:polkitd mode 750, so a normal
        # user cannot lstat an installed rule. The marker is only UI state; it
        # never grants privilege and the actual rule remains enforced by Polkit.
        "polkit_rule_installed": secure_system_file(POLKIT_RULE_PATH, executable=False)
        or user_polkit_marker_installed(),
    }
    try:
        get_credentials(None)
        result["credentials"] = True
    except (OSError, RuntimeError, configparser.Error):
        pass
    print(json.dumps(result))


def secure_system_file(path, executable=False):
    """Only trust regular files below a root-owned, non-writable ancestry."""
    try:
        secure_directory_path(os.path.dirname(os.path.abspath(path)))
        file_stat = os.lstat(path)
    except (OSError, RuntimeError):
        return False
    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_uid != 0 or file_stat.st_mode & 0o022:
        return False
    if executable and not (file_stat.st_mode & 0o111):
        return False
    return True


def user_polkit_marker_path():
    return os.path.join(invoking_user().pw_dir, POLKIT_MARKER_RELATIVE_PATH)


def user_polkit_marker_installed():
    """Read the installer-owned UI marker when the system rule is not traversable."""
    path = user_polkit_marker_path()
    try:
        marker_stat = os.lstat(path)
        user = invoking_user()
        if not stat.S_ISREG(marker_stat.st_mode) or marker_stat.st_uid != user.pw_uid or marker_stat.st_mode & 0o077:
            return False
        with open(path, encoding="ascii") as marker:
            return marker.read(128).strip() == POLKIT_MARKER_CONTENT
    except (OSError, UnicodeError):
        return False


def system_binary(name):
    path = shutil.which(name)
    if not path:
        raise FileNotFoundError(name)
    if os.geteuid() == 0:
        resolved = os.path.realpath(path)
        if not secure_system_file(resolved, executable=True):
            raise RuntimeError(f"Refusing non-root-owned system executable: {path}")
        return resolved
    return path


def system_binary_available(name):
    try:
        system_binary(name)
        return True
    except (FileNotFoundError, RuntimeError):
        return False


def _installed_helper_source():
    """Read a bounded, trusted helper snapshot for version/capability checks."""
    if not secure_system_file(HELPER_BIN_PATH, executable=True):
        return b""
    try:
        file_stat = os.stat(HELPER_BIN_PATH)
        if file_stat.st_size > MAX_HELPER_BYTES:
            return b""
        with open(HELPER_BIN_PATH, "rb") as installed:
            return installed.read(MAX_HELPER_BYTES + 1)
    except OSError:
        return b""


def installed_helper_version():
    """Return the source version embedded in the installed root helper."""
    source = _installed_helper_source()
    if len(source) > MAX_HELPER_BYTES:
        return ""
    match = re.search(rb'^PLUGIN_VERSION = "([^"]+)"$', source, re.MULTILINE)
    return match.group(1).decode("ascii", errors="replace") if match else ""


def secure_helper_present():
    """Return whether the fixed helper is trusted enough for recovery cleanup."""
    return secure_system_file(HELPER_BIN_PATH, executable=True)


def secure_helper_installed():
    """Reject stale helpers that predate the current plugin or capability."""
    source = _installed_helper_source()
    if not source or len(source) > MAX_HELPER_BYTES:
        return False
    capability_marker = f'HELPER_CAPABILITY_VERSION = "{HELPER_CAPABILITY_VERSION}"'.encode("ascii")
    version_marker = f'PLUGIN_VERSION = "{PLUGIN_VERSION}"'.encode("ascii")
    return capability_marker in source and version_marker in source


def installed_helper_invocation():
    """Detect the fixed root helper entrypoint without trusting an argv flag."""
    try:
        return os.geteuid() == 0 and os.path.realpath(sys.argv[0]) == HELPER_BIN_PATH
    except OSError:
        return False


def validate_helper_request(args):
    """Reduce the release interface to native WireGuard lifecycle only."""
    if args.action == "connect" and (
        args.protocol != "wireguard" or args.server_type != "traffic" or args.streaming_service
    ):
        raise RuntimeError("This release supports native WireGuard traffic connections only")
    if not installed_helper_invocation():
        return args
    if args.action not in HELPER_ACTIONS:
        raise RuntimeError("The installed root helper only supports connect and disconnect")
    if args.config or args.city:
        raise RuntimeError("The installed root helper does not accept custom paths or city options")
    if args.action != "connect" and args.server:
        raise RuntimeError("Server selection is only valid for connect")
    if args.action != "connect" and args.streaming_service:
        raise RuntimeError("Streaming service is only valid for connect")
    args.config = user_config_path()
    return args


def status(config_path=None, as_json=False, check_cli=True):
    ip_binary = system_binary("ip")
    ip_res = run_bounded([ip_binary, "link", "show", INTERFACE], timeout=5, max_output_bytes=8 * 1024)
    wireguard_connected = ip_res.returncode == 0 and INTERFACE in (ip_res.stdout or "")

    wg_info = {}
    if wireguard_connected:
        wg_res = run_bounded([system_binary("wg"), "show", INTERFACE], timeout=5, max_output_bytes=8 * 1024)
        if wg_res.returncode == 0:
            wg_info = parse_wg_show(wg_res.stdout)

    cli_connected = False
    cli_status = ""
    if check_cli and not wireguard_connected and system_binary_available("cyberghostvpn"):
        try:
            cli_res = run_bounded(
                [system_binary("cyberghostvpn"), "--status"],
                timeout=10,
                max_output_bytes=8 * 1024,
                env=cyberghost_cli_environment(),
            )
            cli_status = (cli_res.stdout or cli_res.stderr or "").strip()[:512]
            cli_connected = (
                cli_res.returncode == 0
                and not re.search(r"no vpn connection|not connected|disconnected", cli_status, re.I)
                and bool(re.search(r"connected|connection found|running", cli_status, re.I))
            )
        except (FileNotFoundError, subprocess.TimeoutExpired, RuntimeError):
            cli_connected = False

    is_connected = wireguard_connected or cli_connected

    if as_json:
        result = {
            "connected": is_connected,
            "interface": INTERFACE if wireguard_connected else None,
            "backend": "wireguard" if wireguard_connected else ("cyberghostvpn" if cli_connected else None),
        }
        if is_connected:
            result.update(wg_info)
            if cli_connected:
                result["cli_status"] = cli_status
        print(json.dumps(result))
        return

    if wireguard_connected:
        print("VPN connection found.")
        print(f"Interface: {INTERFACE}")
        for key in ("endpoint", "transfer"):
            if key in wg_info:
                print(f"  {key}: {wg_info[key]}")
        if "handshake_sec" in wg_info:
            print(f"  latest handshake: {wg_info['handshake_sec']} seconds ago")
    elif cli_connected:
        print("VPN connection found via cyberghostvpn CLI.")
        if cli_status:
            print(cli_status)
    else:
        print("No VPN connections found.")


def main():
    parser = argparse.ArgumentParser(description="CyberGhost WireGuard Controller")
    parser.add_argument(
        "action",
        choices=["connect", "disconnect", "status", "check", "register", "servers", "streaming-services"],
        help="Action to perform",
    )
    parser.add_argument("--country", "-c", default="PT", help="Country code (e.g. PT, ES, US, DE)")
    parser.add_argument("--server-type", "-t", default="traffic", choices=["traffic", "streaming", "torrent"])
    parser.add_argument("--protocol", default="wireguard", choices=["wireguard", "openvpn", "openvpn_tcp"])
    parser.add_argument("--city", help="Optional city name")
    parser.add_argument("--server", help="Exact CyberGhost server instance from the live inventory")
    parser.add_argument("--streaming-service", help="Streaming profile name reported by cyberghostvpn")
    parser.add_argument("--config", help="Explicit path to ~/.cyberghost/config.ini")
    parser.add_argument("--json", action="store_true", help="Output status or action result as JSON")
    parser.add_argument("--no-cli", action="store_true", help="Skip the vendor CLI status probe")

    args = None
    try:
        args = parser.parse_args()
        args = validate_helper_request(args)
        if args.action == "connect":

            def do_connect():
                if args.protocol == "wireguard" and args.server_type == "traffic":
                    # The native API + wg-quick path is the reliable WireGuard
                    # backend. The vendor CLI is still queried for its current
                    # server inventory when available, but its legacy 1.4.x
                    # WireGuard launcher can report success without creating a
                    # tunnel when run through pkexec.
                    return connect(args.country, args.server_type, args.city, args.config, args.server)
                # OpenVPN, torrent and streaming remain delegated to the
                # vendor CLI because those modes are not covered by the
                # native WireGuard implementation.
                return connect_via_cli(args.country, args.server_type, args.protocol, args.streaming_service)

            if args.json:
                with contextlib.redirect_stdout(io.StringIO()):
                    action_result = do_connect()
                result = {"ok": True, "action": "connect"}
                if isinstance(action_result, dict):
                    result.update(action_result)
                print(json.dumps(result))
            else:
                do_connect()
        elif args.action == "disconnect":
            if args.json:
                with contextlib.redirect_stdout(io.StringIO()):
                    action_result = disconnect()
                result = {"ok": True, "action": "disconnect"}
                if isinstance(action_result, dict):
                    result.update(action_result)
                print(json.dumps(result))
            else:
                disconnect()
        elif args.action == "status":
            status(args.config, args.json, check_cli=False)
        elif args.action == "check":
            check()
        elif args.action == "register":
            register(args.config)
        elif args.action == "servers":
            print(json.dumps(get_servers_for_country(args.country, args.server_type)))
        elif args.action == "streaming-services":
            print(json.dumps(get_streaming_services(args.country)))
    except Exception as e:
        if args is not None and args.json and args.action in HELPER_ACTIONS:
            print(
                json.dumps(
                    {
                        "ok": False,
                        "action": args.action,
                        "error": clean_command_error(e),
                    }
                )
            )
        else:
            sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()

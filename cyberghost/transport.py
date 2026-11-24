"""HTTP transports: pinned endpoint TLS and the account JSON API.

Credential-bearing requests fail closed: TLS verification stays on, a proxy
cannot silently drop the pinning, and bodies are read with hard byte/deadline
limits.
"""

import re
import signal
import socket
import threading
import time
from urllib.parse import urlsplit, urlunsplit

from .constants import ACCOUNT_API_BUDGET_SECONDS, API_BASE, MAX_HTTP_RESPONSE_BYTES, USER_AGENT
from .system import read_response_bounded
from .validation import api_app_key, validate_api_credential


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

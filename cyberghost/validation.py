"""Strict validation at every trust boundary.

CyberGhost and the vendor CLI return remote data that ends up in argv, an INI
file and a NetworkManager profile. Every value is validated here before it is
allowed to leave the process.
"""

import base64
import binascii
import ipaddress
import os
import re

from .constants import DEFAULT_API_KEY


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


def validate_request(args):
    """Reduce the release interface to native WireGuard traffic connections."""
    if args.action == "connect" and (
        args.protocol != "wireguard" or args.server_type != "traffic" or args.streaming_service
    ):
        raise RuntimeError("This release supports native WireGuard traffic connections only")
    if args.action != "connect" and (args.server or args.streaming_service):
        raise RuntimeError("Server and streaming selection are only valid for connect")
    return args

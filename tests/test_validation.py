"""Backend validation regression tests."""

import os
import re
import tempfile
from unittest import mock

from runner_support import ROOT, SAMPLE_PRIV, SAMPLE_PUB, load_runner

runner = load_runner()


def test_city_map_covers_countries_js():
    """Every country offered in the UI must have a native WireGuard city slug."""
    js = (ROOT / "Countries.js").read_text()
    codes = set(re.findall(r'"code":\s*"([A-Z]{2})"', js))
    mapped = set(runner.CITY_MAP)
    missing = codes - mapped
    assert not missing, f"Countries.js codes missing from CITY_MAP: {sorted(missing)}"


def test_ukraine_uses_live_dialup_hostname_spelling():
    """CyberGhost displays Kyiv but publishes its WireGuard hosts as kiev-* names."""
    with mock.patch.object(runner.os, "geteuid", return_value=0):
        country, candidates = runner.select_native_candidates("UA")

    assert country == "UA"
    assert candidates[0] == "kiev-s405-i01.cg-dialup.net"
    assert "kiev-s401-i01.cg-dialup.net" in candidates
    assert not any(candidate.startswith("kyiv-") for candidate in candidates)


def test_validate_wireguard_key():
    assert runner.validate_wireguard_key(SAMPLE_PRIV) == SAMPLE_PRIV
    assert runner.validate_wireguard_key(SAMPLE_PUB) == SAMPLE_PUB

    # Injection attempts / malformed keys must be rejected
    invalid_keys = [
        SAMPLE_PRIV + "\nPreUp = touch /tmp/pwned",
        SAMPLE_PRIV + "\r\nPostUp = bash -c 'id'",
        "short_key=",
        "not_base_64!===============================",
        "",
        12345,
    ]
    for ik in invalid_keys:
        try:
            runner.validate_wireguard_key(ik)
            raise AssertionError(f"Expected ValueError for invalid key: {ik!r}")
        except (ValueError, TypeError):
            pass


def test_validate_ip():
    assert runner.validate_ip("10.2.0.2") == "10.2.0.2"
    assert runner.validate_ip("1.1.1.1") == "1.1.1.1"
    assert runner.validate_ip("2001:db8::1") == "2001:db8::1"

    # Injection attempts / invalid IPs
    invalid_ips = [
        "10.2.0.2\nPreUp = touch /tmp/pwned",
        "10.2.0.2/24",
        "999.999.999.999",
        "1.2.3.4; rm -rf /",
        "",
        None,
    ]
    for ip in invalid_ips:
        try:
            runner.validate_ip(ip)
            raise AssertionError(f"Expected ValueError for invalid IP: {ip!r}")
        except (ValueError, TypeError):
            pass


def test_validate_port():
    assert runner.validate_port(1337) == 1337
    assert runner.validate_port("51820") == 51820
    assert runner.validate_port(1) == 1
    assert runner.validate_port(65535) == 65535

    invalid_ports = [0, 65536, -1, "1337\nPreUp=touch /tmp/pwned", "abc", None]
    for p in invalid_ports:
        try:
            runner.validate_port(p)
            raise AssertionError(f"Expected ValueError for invalid port: {p!r}")
        except (ValueError, TypeError):
            pass


def test_validate_country_code():
    assert runner.validate_country_code("pt") == "PT"
    assert runner.validate_country_code(" US ") == "US"
    for code in ("P!", "PT1", "P", "", None):
        try:
            runner.validate_country_code(code)
            raise AssertionError(f"Expected ValueError for invalid country code: {code!r}")
        except (ValueError, TypeError):
            pass


def test_validate_server_selector():
    assert runner.validate_server_selector("Lisbon-s405-i19") == "lisbon-s405-i19"
    for server in ("50", "lisbon-s50", "lisbon-s405-i19.cg-dialup.net", "lisbon s405 i19", "", None):
        try:
            runner.validate_server_selector(server)
            raise AssertionError(f"Expected ValueError for invalid server: {server!r}")
        except (ValueError, TypeError):
            pass


def test_validate_streaming_service():
    assert runner.validate_streaming_service("Netflix US") == "Netflix US"
    for service in ("", "x\n--connect", "x" * 129, None):
        try:
            runner.validate_streaming_service(service)
            raise AssertionError(f"Expected ValueError for invalid streaming service: {service!r}")
        except (ValueError, TypeError):
            pass


def test_validate_endpoint_host():
    assert runner.validate_endpoint_host("1.2.3.4") == "1.2.3.4"
    assert runner.validate_endpoint_host("lisbon-s405-i01.cg-dialup.net") == "lisbon-s405-i01.cg-dialup.net"

    invalid_hosts = [
        "lisbon-s405.cg-dialup.net\nPreUp = touch /tmp/pwned",
        "host with spaces.net",
        "host;rm -rf /",
        "",
        None,
    ]
    for h in invalid_hosts:
        try:
            runner.validate_endpoint_host(h)
            raise AssertionError(f"Expected ValueError for invalid host: {h!r}")
        except (ValueError, TypeError):
            pass


def test_validate_dns_servers():
    assert runner.validate_dns_servers(["10.0.0.243", "1.1.1.1"], require_nonempty=True) == "10.0.0.243, 1.1.1.1"
    assert runner.validate_dns_servers("10.0.0.243, 1.1.1.1", require_nonempty=True) == "10.0.0.243, 1.1.1.1"

    for invalid in (None, "", " , ", [], [""], False, 0, {"dns": "1.1.1.1"}):
        try:
            runner.validate_dns_servers(invalid, require_nonempty=True)
            raise AssertionError(f"Expected a non-empty DNS validation error for {invalid!r}")
        except (ValueError, TypeError):
            pass

    assert runner.validate_dns_servers(["2001:4860:4860::8888"], require_nonempty=True) == "2001:4860:4860::8888"

    # Newline injection attempt in DNS
    try:
        runner.validate_dns_servers(["10.0.0.243\nPostUp = id", "1.1.1.1"], require_nonempty=True)
        raise AssertionError("Expected ValueError for injected DNS")
    except ValueError:
        pass


def test_build_wg_config_routes_both_families_and_rejects_injection():
    cfg = runner.build_wg_config(SAMPLE_PRIV, "10.2.0.2", SAMPLE_PUB, "1.2.3.4", 1337, dns_servers="1.1.1.1")
    assert "AllowedIPs = 0.0.0.0/0, ::/0" in cfg
    assert f"PrivateKey = {SAMPLE_PRIV}" in cfg
    assert f"PublicKey = {SAMPLE_PUB}" in cfg
    assert "DNS = 1.1.1.1" in cfg
    assert "Endpoint = 1.2.3.4:1337" in cfg
    assert cfg.endswith("PersistentKeepalive = 25\n")

    ipv6_cfg = runner.build_wg_config(
        SAMPLE_PRIV, "10.2.0.2", SAMPLE_PUB, "2001:db8::1", 1337, dns_servers="2001:4860:4860::8888"
    )
    assert "DNS = 2001:4860:4860::8888" in ipv6_cfg

    # Test that directive injection is strictly rejected
    try:
        runner.build_wg_config(SAMPLE_PRIV + "\nPreUp = touch /tmp/pwned", "10.2.0.2", SAMPLE_PUB, "1.2.3.4", 1337)
        raise AssertionError("Expected ValueError for injected private key")
    except ValueError:
        pass

    assert "Endpoint = [2001:db8::1]:1337" in ipv6_cfg

    ipv6_peer_cfg = runner.build_wg_config(
        SAMPLE_PRIV, "2001:db8::2", SAMPLE_PUB, "1.2.3.4", 1337, dns_servers="1.1.1.1"
    )
    assert "Address = 2001:db8::2/128" in ipv6_peer_cfg

    try:
        runner.build_wg_config(SAMPLE_PRIV, "10.2.0.2\nPreUp = touch /tmp/pwned", SAMPLE_PUB, "1.2.3.4", 1337)
        raise AssertionError("Expected ValueError for injected peer IP")
    except ValueError:
        pass


def test_parse_handshake_seconds():
    assert runner.parse_handshake_seconds("latest handshake: 2 minutes, 34 seconds ago") == 154
    assert runner.parse_handshake_seconds("5 seconds ago") == 5
    assert runner.parse_handshake_seconds("1 hour 30 minutes ago") == 5400
    assert runner.parse_handshake_seconds("2 days ago") == 172800
    assert runner.parse_handshake_seconds("never") is None
    assert runner.parse_handshake_seconds("") is None


def test_parse_wg_show():
    sample = (
        "interface: cyberghost\n"
        "  public key: abcdef=\n"
        "  endpoint: 1.2.3.4:1337\n"
        "  allowed ips: 0.0.0.0/0\n"
        "  transfer: 1.5 GiB received, 200 MiB sent\n"
        "  latest handshake: 1 minute, 12 seconds ago\n"
    )
    info = runner.parse_wg_show(sample)
    assert info["endpoint"] == "1.2.3.4:1337"
    assert info["handshake_sec"] == 72
    assert "received" in info["transfer"]
    assert "public key" not in info


def test_validate_user_config_size_limit():
    d = tempfile.mkdtemp()
    oversized = os.path.join(d, "huge_config.ini")
    with open(oversized, "w") as f:
        f.write("#" * 70000)
    try:
        runner.get_credentials(oversized)
        raise AssertionError("Expected RuntimeError for oversized config")
    except RuntimeError as e:
        assert "exceeds maximum size" in str(e)


def test_countries_js_consistency():
    js = (ROOT / "Countries.js").read_text()
    codes = re.findall(r'"code":\s*"([A-Z]{2})"', js)
    names = re.findall(r'"name":\s*"([^"]+)"', js)
    popular_match = re.search(r"var popularCodes = \[(.*?)\];", js, re.S)
    assert len(codes) >= 90, f"Expected 90+ countries, found {len(codes)}"
    assert len(codes) == len(set(codes)), "Duplicate country codes found in Countries.js"
    assert len(codes) == len(names), "Mismatch between country codes and names in Countries.js"
    assert popular_match, "Missing popular country list"
    popular_codes = re.findall(r'"([A-Z]{2})"', popular_match.group(1))
    assert popular_codes == ["PT", "ES", "GB", "US", "DE", "FR", "NL", "CH"]

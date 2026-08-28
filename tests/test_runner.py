"""Unit tests for cyberghost_runner.py.

Run with pytest (pytest -q) or directly (python3 tests/test_runner.py).
"""

import base64
import configparser
import importlib.util
import json
import os
import pathlib
import re
import sys
import tempfile
import time
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_runner():
    spec = importlib.util.spec_from_file_location("cyberghost_runner", ROOT / "cyberghost_runner.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


runner = load_runner()

# Valid WireGuard test keys (32 bytes base64 encoded = 44 chars ending in =)
SAMPLE_PRIV = base64.b64encode(b"A" * 32).decode("ascii")
SAMPLE_PUB = base64.b64encode(b"B" * 32).decode("ascii")


def test_city_map_covers_countries_js():
    """Every country offered in the UI must have a native WireGuard city slug."""
    js = (ROOT / "Countries.js").read_text()
    codes = set(re.findall(r'"code":\s*"([A-Z]{2})"', js))
    mapped = set(runner.CITY_MAP)
    missing = codes - mapped
    assert not missing, f"Countries.js codes missing from CITY_MAP: {sorted(missing)}"


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


def test_server_inventory_uses_real_city_instances_and_sorts_load():
    table = (
        "+-----+--------+-----------------+------+\n"
        "| No. |  City  |     Instance    | Load |\n"
        "+-----+--------+-----------------+------+\n"
        "|  1  | Lisbon | lisbon-s405-i01 | 51%  |\n"
        "|  2  | Lisbon | lisbon-s405-i19 | 18%  |\n"
        "+-----+--------+-----------------+------+\n"
    )
    completed = runner.subprocess.CompletedProcess([], 0, table, "")
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/cyberghostvpn"):
        with mock.patch.object(runner, "run_bounded", return_value=completed) as run_mock:
            servers = runner.get_servers_for_country("PT")

    assert servers == [
        {"city": "Lisbon", "instance": "lisbon-s405-i19", "server": "lisbon-s405-i19", "load": 18},
        {"city": "Lisbon", "instance": "lisbon-s405-i01", "server": "lisbon-s405-i01", "load": 51},
    ]
    command = run_mock.call_args.args[0]
    assert command[-2:] == ["--city", "lisbon"]


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
    assert runner.validate_dns_servers(["10.0.0.243", "1.1.1.1"]) == "10.0.0.243, 1.1.1.1"
    assert runner.validate_dns_servers("10.0.0.243, 1.1.1.1") == "10.0.0.243, 1.1.1.1"
    assert runner.validate_dns_servers("") == ""
    assert runner.validate_dns_servers(None) == ""

    # Newline injection attempt in DNS
    try:
        runner.validate_dns_servers(["10.0.0.243\nPostUp = id", "1.1.1.1"])
        raise AssertionError("Expected ValueError for injected DNS")
    except ValueError:
        pass


def test_build_wg_config_blocks_ipv6_leak_and_injection():
    cfg = runner.build_wg_config(SAMPLE_PRIV, "10.2.0.2", SAMPLE_PUB, "1.2.3.4", 1337, dns_servers="1.1.1.1")
    assert "AllowedIPs = 0.0.0.0/0, ::/0" in cfg
    assert f"PrivateKey = {SAMPLE_PRIV}" in cfg
    assert f"PublicKey = {SAMPLE_PUB}" in cfg
    assert "DNS = 1.1.1.1" in cfg
    assert "Endpoint = 1.2.3.4:1337" in cfg
    assert cfg.endswith("PersistentKeepalive = 25\n")

    lean = runner.build_wg_config(SAMPLE_PRIV, "10.2.0.2", SAMPLE_PUB, "1.2.3.4", 1337)
    assert "DNS" not in lean

    # Test that directive injection is strictly rejected
    try:
        runner.build_wg_config(SAMPLE_PRIV + "\nPreUp = touch /tmp/pwned", "10.2.0.2", SAMPLE_PUB, "1.2.3.4", 1337)
        raise AssertionError("Expected ValueError for injected private key")
    except ValueError:
        pass

    ipv6_cfg = runner.build_wg_config(SAMPLE_PRIV, "10.2.0.2", SAMPLE_PUB, "2001:db8::1", 1337)
    assert "Endpoint = [2001:db8::1]:1337" in ipv6_cfg

    ipv6_peer_cfg = runner.build_wg_config(SAMPLE_PRIV, "2001:db8::2", SAMPLE_PUB, "1.2.3.4", 1337)
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


def test_find_config_path_env_override():
    with tempfile.NamedTemporaryFile(suffix=".ini") as tf:
        old = os.environ.get("CYBERGHOST_CONFIG")
        os.environ["CYBERGHOST_CONFIG"] = tf.name
        try:
            assert runner.find_config_path() == tf.name
        finally:
            if old is None:
                del os.environ["CYBERGHOST_CONFIG"]
            else:
                os.environ["CYBERGHOST_CONFIG"] = old


def test_reject_symlink_config():
    d = tempfile.mkdtemp()
    target_real = os.path.join(d, "real_config.ini")
    symlink_path = os.path.join(d, "symlink_config.ini")
    with open(target_real, "w") as f:
        f.write("[device]\ntoken = T\nsecret = S\n")
    os.symlink(target_real, symlink_path)

    # get_credentials must raise RuntimeError if pointed to a symlink
    try:
        runner.get_credentials(symlink_path)
        raise AssertionError("Expected RuntimeError when loading config from symlink")
    except RuntimeError as e:
        assert "symlink" in str(e).lower()


def test_check_output_shape():
    import io
    from contextlib import redirect_stdout

    buf = io.StringIO()
    with mock.patch.object(runner, "system_binary_available", return_value=False):
        with mock.patch.object(runner.importlib.util, "find_spec", return_value=object()):
            with mock.patch.object(runner, "get_credentials", side_effect=RuntimeError("not configured")):
                with mock.patch.object(runner, "secure_helper_installed", return_value=False):
                    with mock.patch.object(runner, "installed_helper_version", return_value=""):
                        with mock.patch.object(runner, "secure_system_file", return_value=False):
                            with mock.patch.object(runner, "user_polkit_marker_installed", return_value=False):
                                with redirect_stdout(buf):
                                    runner.check()
    data = json.loads(buf.getvalue())
    expected_keys = {
        "wg_tools",
        "requests",
        "cli",
        "credentials",
        "helper_installed",
        "helper_version",
        "plugin_version",
        "polkit_rule_installed",
    }
    assert set(data) == expected_keys
    for key, value in data.items():
        if key in {"helper_version", "plugin_version"}:
            assert isinstance(value, str)
        else:
            assert isinstance(value, bool)


def test_api_app_key_allows_safe_vendor_rotation_override():
    with mock.patch.dict(os.environ, {"CG_APP_KEY": "rotated-public-key"}, clear=False):
        assert runner.api_app_key() == "rotated-public-key"
    with mock.patch.dict(os.environ, {"CG_APP_KEY": "bad\nheader"}, clear=False):
        try:
            runner.api_app_key()
            raise AssertionError("Expected control characters to be rejected")
        except RuntimeError as exc:
            assert "application key" in str(exc)


def test_api_request_uses_direct_verified_session():
    response = mock.Mock()
    response.headers = {}
    response.iter_content.return_value = []
    response._cyberghost_body = b"{}"
    session = mock.Mock()
    session.request.return_value = response
    requests_stub = mock.Mock()
    requests_stub.Session.return_value = session
    with mock.patch.object(runner, "load_requests", return_value=requests_stub):
        assert runner.api_request("POST", "/test", payload={"ok": True}) is response

    assert session.trust_env is False
    session.request.assert_called_once()
    assert session.request.call_args.kwargs["verify"] is True
    assert session.request.call_args.kwargs["allow_redirects"] is False


def test_register_payload_shapes():
    login = runner.build_login_payload("user@example.com", "pw")
    assert login == {"userName": "user@example.com", "password": "pw"}

    device = runner.build_device_payload("omarchy")
    assert device["data"]["linuxApp"] is True
    assert device["data"]["machineName"] == "omarchy"


def test_write_user_config():
    d = tempfile.mkdtemp()
    path = os.path.join(d, ".cyberghost", "config.ini")
    os.makedirs(os.path.dirname(path), exist_ok=True)

    runner.write_user_config(
        path,
        "user@example.com",
        "omarchy",
        {"name": "", "token": "TOK", "tokenSecret": "SEC"},
    )
    cfg = configparser.ConfigParser()
    cfg.read(path)
    assert cfg.get("account", "username") == "user@example.com"
    assert not cfg.has_option("account", "password")
    assert cfg.get("device", "name") == "omarchy"  # falls back to device_name
    assert cfg.get("device", "token") == "TOK"
    assert cfg.get("device", "secret") == "SEC"  # tokenSecret -> secret
    assert not (os.stat(path).st_mode & 0o077)  # owner-only permissions
    assert not (os.stat(os.path.dirname(path)).st_mode & 0o077)


def test_run_bounded_rejects_excessive_output():
    try:
        runner.run_bounded(
            [sys.executable, "-c", "print('x' * 256)"],
            timeout=5,
            max_output_bytes=64,
        )
        raise AssertionError("Expected output limit to terminate the command")
    except RuntimeError as exc:
        assert "output exceeded" in str(exc)


def test_cli_environment_uses_pkexec_initiating_user_home():
    initiating_user = mock.Mock(pw_dir="/home/miguel", pw_name="miguel")
    with mock.patch.object(runner.os, "geteuid", return_value=0):
        with mock.patch.dict(
            runner.os.environ,
            {
                "PKEXEC_UID": "1000",
                "PYTHONPATH": "/tmp",
                "LD_PRELOAD": "evil.so",
                "BASH_ENV": "/tmp/evil.sh",
                "XDG_CONFIG_HOME": "/tmp/config",
            },
            clear=False,
        ):
            with mock.patch.object(runner, "invoking_user", return_value=initiating_user):
                env = runner.cyberghost_cli_environment()

    assert env["HOME"] == "/home/miguel"
    assert env["USER"] == "miguel"
    assert env["LOGNAME"] == "miguel"
    assert env["PATH"] == "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    assert "PYTHONPATH" not in env
    assert "LD_PRELOAD" not in env
    assert "BASH_ENV" not in env
    assert "XDG_CONFIG_HOME" not in env


def test_server_inventory_reports_expected_failures_to_stderr():
    import io
    from contextlib import redirect_stderr

    error = io.StringIO()
    with mock.patch.object(runner, "system_binary", side_effect=RuntimeError("CLI unavailable")):
        with redirect_stderr(error):
            assert runner.get_servers_for_country("PT") == []
    assert "Server inventory unavailable for PT" in error.getvalue()
    assert "CLI unavailable" in error.getvalue()


def test_streaming_service_discovery_and_cli_arguments():
    table = (
        "+-----+-----------------------+--------------+\n"
        "| No. |        Service        | Country Code |\n"
        "+-----+-----------------------+--------------+\n"
        "|  1  |       Netflix US      |      US      |\n"
        "|  2  |       Netflix DE      |      DE      |\n"
    )
    completed = runner.subprocess.CompletedProcess(["cyberghostvpn"], 0, table, "")
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/cyberghostvpn"):
        with mock.patch.object(runner, "run_bounded", return_value=completed) as run_mock:
            services = runner.get_streaming_services("US")
            assert services == [{"value": "Netflix US", "label": "Netflix US"}]

        completed_empty = runner.subprocess.CompletedProcess([], 0, "Server not found in cache\n", "")
        with mock.patch.object(runner, "run_bounded", return_value=completed_empty) as run_mock:
            runner.connect_via_cli("US", "streaming", "wireguard", "Netflix US")
            command = run_mock.call_args.args[0]
            assert command == [
                "/usr/bin/cyberghostvpn",
                "--streaming",
                "Netflix US",
                "--wireguard",
                "--country-code",
                "US",
                "--connect",
            ]


def test_connect_via_cli_includes_context_in_error_fallback():
    """A cyberghostvpn error with no useful stdout must surface country / protocol / mode context."""

    # Empty stdout/stderr: clean_command_error returns the fallback.
    empty_failure = runner.subprocess.CompletedProcess(["cyberghostvpn"], 7, "", "")
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/cyberghostvpn"):
        with mock.patch.object(runner, "run_bounded", return_value=empty_failure):
            try:
                runner.connect_via_cli("US", "torrent", "openvpn")
            except RuntimeError as exc:
                message = str(exc)
                assert "US" in message
                assert "openvpn" in message
                assert "torrent" in message
                assert "exit 7" in message
            else:
                raise AssertionError("Expected a non-zero exit to surface")

    # Streaming mode adds the streaming service name to the context.
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/cyberghostvpn"):
        with mock.patch.object(runner, "run_bounded", return_value=empty_failure):
            try:
                runner.connect_via_cli("DE", "streaming", "wireguard", "Netflix DE")
            except RuntimeError as exc:
                message = str(exc)
                assert "Netflix DE" in message
            else:
                raise AssertionError("Expected a non-zero exit to surface")

    # Timeout path also carries the context.
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/cyberghostvpn"):
        with mock.patch.object(
            runner, "run_bounded", side_effect=runner.subprocess.TimeoutExpired(["cyberghostvpn"], 120)
        ):
            try:
                runner.connect_via_cli("PT", "traffic", "wireguard")
            except RuntimeError as exc:
                assert "PT" in str(exc)
                assert "wireguard" in str(exc)
                assert "timed out" in str(exc)
            else:
                raise AssertionError("Expected a CLI timeout to surface")


def test_native_api_runtime_errors_are_returned_without_traceback():
    requests_stub = mock.Mock()
    requests_stub.exceptions.RequestException = Exception
    with mock.patch.object(runner, "get_credentials", return_value=("TOK", "SEC")):
        with mock.patch.object(runner, "generate_wireguard_keys", return_value=(SAMPLE_PRIV, SAMPLE_PUB)):
            with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
                with mock.patch.object(runner, "load_requests", return_value=requests_stub):
                    with mock.patch.object(
                        runner, "api_get", side_effect=RuntimeError("TLS certificate hostname mismatch")
                    ):
                        try:
                            runner.connect("PT", "traffic")
                            raise AssertionError("Expected the native API failure to be reported")
                        except RuntimeError as exc:
                            message = str(exc)
                            assert "TLS certificate hostname mismatch" in message
                            assert "Traceback" not in message


def test_clean_command_error_drops_partial_traceback():
    raw = 'Traceback (most recent call last):\n  File "cyberghost_runner.py", line 738\n    r = api_get(url)'
    assert runner.clean_command_error(raw, "Try again") == "Try again"


def test_main_uses_native_wireguard_for_traffic_even_when_cli_exists():
    original_argv = runner.sys.argv
    try:
        runner.sys.argv = [
            "cyberghost_runner.py",
            "connect",
            "--country",
            "PT",
            "--protocol",
            "wireguard",
            "--server-type",
            "traffic",
        ]
        with mock.patch.object(runner, "connect_via_cli") as cli_mock:
            with mock.patch.object(runner, "connect") as native_mock:
                runner.main()
        native_mock.assert_called_once_with("PT", "traffic", None, None, None)
        cli_mock.assert_not_called()
    finally:
        runner.sys.argv = original_argv


def test_main_delegates_non_wireguard_modes_to_cli():
    original_argv = runner.sys.argv
    try:
        runner.sys.argv = [
            "cyberghost_runner.py",
            "connect",
            "--country",
            "PT",
            "--protocol",
            "openvpn",
            "--server-type",
            "traffic",
        ]
        with mock.patch.object(runner, "connect_via_cli") as cli_mock:
            with mock.patch.object(runner, "connect") as native_mock:
                runner.main()
        cli_mock.assert_called_once_with("PT", "traffic", "openvpn", None)
        native_mock.assert_not_called()
    finally:
        runner.sys.argv = original_argv


def test_main_passes_manual_server_to_native_wireguard():
    original_argv = runner.sys.argv
    try:
        runner.sys.argv = [
            "cyberghost_runner.py",
            "connect",
            "--country",
            "PT",
            "--protocol",
            "wireguard",
            "--server-type",
            "traffic",
            "--server",
            "lisbon-s405-i19",
        ]
        with mock.patch.object(runner, "connect") as native_mock:
            runner.main()
        native_mock.assert_called_once_with("PT", "traffic", None, None, "lisbon-s405-i19")
    finally:
        runner.sys.argv = original_argv


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


def test_manifest_schema_and_validity():
    manifest_path = ROOT / "manifest.json"
    assert manifest_path.is_file()
    data = json.loads(manifest_path.read_text())

    assert data.get("id") == "miguel.cyberghost"
    assert data.get("version") == runner.PLUGIN_VERSION
    assert data.get("entryPoints", {}).get("barWidget") == "Panel.qml"
    assert "barWidget" in data

    defaults = data["barWidget"].get("defaults", {})
    schema = data["barWidget"].get("schema", [])
    schema_keys = {item["key"]: item for item in schema}

    # Verify all defaults match schema types
    for key, val in defaults.items():
        assert key in schema_keys, f"Default key {key} not found in schema"
        schema_item = schema_keys[key]
        expected_type = schema_item["type"]
        if expected_type == "integer":
            assert isinstance(val, int)
        elif expected_type == "string":
            assert isinstance(val, str)
        elif expected_type == "boolean":
            assert isinstance(val, bool)


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


def test_status_json_structure():
    import io
    from contextlib import redirect_stdout

    buf = io.StringIO()
    ip_down = runner.subprocess.CompletedProcess(["ip"], 1, "", "")
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/ip"):
        with mock.patch.object(runner, "system_binary_available", return_value=False):
            with mock.patch.object(runner, "run_bounded", return_value=ip_down):
                with redirect_stdout(buf):
                    runner.status(as_json=True)
    out = json.loads(buf.getvalue())
    assert "connected" in out
    assert isinstance(out["connected"], bool)
    assert "interface" in out


def test_status_no_cli_skips_vendor_probe():
    import io
    from contextlib import redirect_stdout

    buf = io.StringIO()
    ip_down = runner.subprocess.CompletedProcess(["ip"], 1, "", "")
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/ip"):
        with mock.patch.object(
            runner, "system_binary_available", side_effect=AssertionError("CLI probe was not expected")
        ):
            with mock.patch.object(runner, "run_bounded", return_value=ip_down):
                with redirect_stdout(buf):
                    runner.status(as_json=True, check_cli=False)
    assert json.loads(buf.getvalue())["connected"] is False


def test_root_helper_rejects_non_lifecycle_actions():
    original_argv = runner.sys.argv
    try:
        runner.sys.argv = [runner.HELPER_BIN_PATH, "register"]
        with mock.patch.object(runner, "installed_helper_invocation", return_value=True):
            args = mock.Mock(action="register", config=None, city=None, json=False)
            try:
                runner.validate_helper_request(args)
                raise AssertionError("Expected the installed helper to reject register")
            except RuntimeError as exc:
                assert "only supports connect and disconnect" in str(exc)
    finally:
        runner.sys.argv = original_argv


def test_root_helper_rejects_custom_config():
    with mock.patch.object(runner, "installed_helper_invocation", return_value=True):
        args = mock.Mock(action="connect", config="/tmp/other.ini", city=None, json=False)
        try:
            runner.validate_helper_request(args)
            raise AssertionError("Expected the installed helper to reject a custom config")
        except RuntimeError as exc:
            assert "custom paths" in str(exc)


def test_ui_privilege_boundary_contract():
    service = (ROOT / "Service.qml").read_text()
    assert '["/usr/bin/pkexec", root.helperPath]' in service
    assert '"pkexec", "/usr/bin/install"' not in service
    assert "install-helper.sh" in service
    assert 'pkexec", "/usr/bin/python3"' not in service
    assert 'pkexec", "sh"' not in service
    assert "StdioCollector" not in service
    assert '"CG_PASSWORD"' not in service
    assert '"servers"' in service
    assert '"--server"' in service
    assert "https://ipwho.is/" in service

    runner_source = (ROOT / "cyberghost_runner.py").read_text()
    assert 'HELPER_CAPABILITY_VERSION = "5"' in runner_source


def test_polkit_marker_is_user_owned_ui_state():
    marker_dir = pathlib.Path(tempfile.mkdtemp())
    marker = marker_dir / "polkit-rule-installed"
    marker.write_text(runner.POLKIT_MARKER_CONTENT + "\n", encoding="ascii")
    marker.chmod(0o600)
    fake_user = mock.Mock(pw_dir=str(marker_dir), pw_uid=os.getuid())
    with mock.patch.object(runner, "invoking_user", return_value=fake_user):
        with mock.patch.object(runner, "POLKIT_MARKER_RELATIVE_PATH", "polkit-rule-installed"):
            assert runner.user_polkit_marker_installed() is True


def test_helper_installer_binds_a_pre_authentication_snapshot():
    installer = (ROOT / "install-helper.sh").read_text()
    privileged_install_lines = [
        line for line in installer.splitlines() if "/usr/bin/sudo" in line and "/usr/bin/install" in line
    ]

    assert "SNAPSHOT_DIR" in installer
    assert "sha256sum" in installer
    assert "copy_to_root_stage" in installer
    assert "verify_root_stage" in installer
    assert "0400" in installer
    assert privileged_install_lines
    assert all("$DIR/" not in line for line in privileged_install_lines)
    assert '"$ROOT_STAGE_DIR/cyberghost_runner.py"' in installer
    assert '"$ROOT_STAGE_DIR/50-cyberghost.rules"' in installer


def test_dialup_tls_target_maps_hostname_and_preserves_request():
    addresses = [(runner.socket.AF_INET, runner.socket.SOCK_STREAM, 6, "", ("198.51.100.10", 1337))]
    with mock.patch.object(runner.socket, "getaddrinfo", return_value=addresses) as resolve:
        canonical, connect_host = runner.dialup_tls_target(
            "https://lisbon-s405-i19.cg-dialup.net:1337/addKey?pubkey=test"
        )

    assert canonical == "https://lisbon-rack405.nodes.gen4.ninja:1337/addKey?pubkey=test"
    assert connect_host == "198.51.100.10"
    resolve.assert_called_once_with("lisbon-s405-i19.cg-dialup.net", 1337, type=runner.socket.SOCK_STREAM)

    passthrough = "https://example.com/path"
    assert runner.dialup_tls_target(passthrough) == (passthrough, None)
    try:
        runner.dialup_tls_target("http://lisbon-s405-i19.cg-dialup.net:1337/addKey")
        raise AssertionError("Expected HTTPS-only endpoint validation")
    except RuntimeError as exc:
        assert "HTTPS" in str(exc)


def test_dialup_tls_target_reports_resolution_failure():
    with mock.patch.object(runner.socket, "getaddrinfo", side_effect=OSError("no DNS")):
        try:
            runner.dialup_tls_target("https://lisbon-s405-i19.cg-dialup.net:1337/addKey")
            raise AssertionError("Expected endpoint resolution failure")
        except RuntimeError as exc:
            assert "Could not resolve CyberGhost endpoint" in str(exc)


def test_dialup_tls_target_bounds_dns_resolution():
    def slow_resolution(*args, **kwargs):
        time.sleep(1)
        return []

    with mock.patch.object(runner.socket, "getaddrinfo", side_effect=slow_resolution):
        started = time.monotonic()
        try:
            runner.dialup_tls_target("https://lisbon-s405-i19.cg-dialup.net:1337/addKey", timeout=0.01)
            raise AssertionError("Expected DNS timeout")
        except RuntimeError as exc:
            assert "DNS timed out" in str(exc)
    assert time.monotonic() - started < 0.5


def test_mapped_https_get_uses_pinned_session_without_proxy():
    try:
        import requests
    except ImportError:
        # requests is installed in CI; the local setup wizard intentionally
        # supports running before this optional runtime dependency is present.
        return

    runner._reset_mapped_https_probe()
    try:
        response = object()
        session = requests.Session()
        with mock.patch.object(
            runner,
            "dialup_tls_target",
            return_value=("https://lisbon-rack405.nodes.gen4.ninja:1337/addKey", "198.51.100.10"),
        ):
            with mock.patch.object(requests, "Session", return_value=session):
                with mock.patch.object(session, "get", return_value=response) as get_mock:
                    assert (
                        runner.mapped_https_get(
                            requests,
                            "https://lisbon-s405-i19.cg-dialup.net:1337/addKey",
                            timeout=(1, 1),
                        )
                        is response
                    )

        assert session.trust_env is False
        get_mock.assert_called_once_with("https://lisbon-rack405.nodes.gen4.ninja:1337/addKey", timeout=(1, 1))
        # The probe is cached as successful after the first pinned call.
        assert runner._MAPPED_HTTPS_PROBE_OK is True
        # The adapter classes are cached so a second call does not re-import
        # the urllib3 internals (and so we do not pay the probe cost again).
        cached_classes = runner._MAPPED_ADAPTER_CLASSES
        assert cached_classes is not None
    finally:
        runner._reset_mapped_https_probe()


def test_mapped_https_probe_fails_closed_when_urllib3_drift_breaks_adapter():
    """When urllib3 moves the private symbols the adapter depends on, the probe must fail before any request is sent."""
    runner._reset_mapped_https_probe()
    try:
        with mock.patch.object(
            runner, "_build_mapped_adapter_classes", side_effect=AttributeError("simulated urllib3 drift")
        ):
            try:
                runner._ensure_mapped_https_probe()
            except RuntimeError as exc:
                assert "pinned CyberGhost TLS adapter" in str(exc)
                assert "Upgrade python-requests" in str(exc)
            else:
                raise AssertionError("Expected the probe to fail closed")

        # The failure is cached, so a second call raises the same way
        # without re-running the broken code path.
        with mock.patch.object(
            runner, "_build_mapped_adapter_classes", side_effect=AssertionError("probe should be cached")
        ):
            try:
                runner._ensure_mapped_https_probe()
            except RuntimeError as exc:
                assert "pinned CyberGhost TLS adapter" in str(exc)
    finally:
        runner._reset_mapped_https_probe()


def test_run_bounded_timeout_kills_child_and_does_not_block_on_stdin():
    try:
        runner.run_bounded(
            [sys.executable, "-c", "import time; time.sleep(10)"],
            timeout=0.1,
            input_data=b"x" * 32768,
        )
        raise AssertionError("Expected subprocess timeout")
    except runner.subprocess.TimeoutExpired:
        pass


def test_read_response_bounded_closes_and_limits_body():
    response = mock.Mock()
    response.headers = {}
    response.iter_content.return_value = [b"hello", b" world"]
    assert runner.read_response_bounded(response) == b"hello world"
    response.close.assert_called_once_with()

    oversized = mock.Mock()
    oversized.headers = {}
    oversized.iter_content.return_value = [b"12345", b"6"]
    try:
        runner.read_response_bounded(oversized, max_bytes=5)
        raise AssertionError("Expected response size failure")
    except RuntimeError as exc:
        assert "exceeds" in str(exc)
    oversized.close.assert_called_once_with()

    expired = mock.Mock()
    expired.headers = {}
    expired.iter_content.return_value = [b"late"]
    try:
        runner.read_response_bounded(expired, deadline=0)
        raise AssertionError("Expected HTTP deadline failure")
    except RuntimeError as exc:
        assert "timed out" in str(exc)
    expired.close.assert_called_once_with()


def test_disconnect_cleans_native_and_cli_state():
    import io
    from contextlib import redirect_stdout

    def bounded(command, **kwargs):
        if command[0] == "/usr/bin/ip" and command[1:3] == ["link", "show"]:
            return runner.subprocess.CompletedProcess(command, 0, "3: cyberghost: <POINTOPOINT>\n", "")
        return runner.subprocess.CompletedProcess(command, 0, "", "")

    output = io.StringIO()
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/ip"):
        with mock.patch.object(runner, "run_bounded", side_effect=bounded) as run_mock:
            with mock.patch.object(runner, "cyberghost_cli_environment", return_value=None):
                with mock.patch.object(runner.os.path, "exists", return_value=False):
                    with redirect_stdout(output):
                        result = runner.disconnect()

    assert result == {"backend": "wireguard", "connected": False}
    assert any(call.args[0][0:3] == ["/usr/bin/ip", "link", "delete"] for call in run_mock.call_args_list)
    assert "VPN connection terminated." in output.getvalue()


def _native_success_response():
    response = mock.Mock(status_code=200)
    response._cyberghost_body = json.dumps(
        {
            "status": "OK",
            "server_key": SAMPLE_PUB,
            "server_ip": "198.51.100.20",
            "server_port": 1337,
            "peer_ip": "10.2.0.2",
            "dns_servers": ["1.1.1.1"],
        }
    ).encode()
    return response


def test_connect_writes_and_activates_native_tunnel():
    d = tempfile.mkdtemp()
    conf_path = os.path.join(d, "cyberghost.conf")

    def bounded(command, **kwargs):
        if command[1] == "up":
            return runner.subprocess.CompletedProcess(command, 0, "interface up", "")
        return runner.subprocess.CompletedProcess(command, 1, "", "not found")

    requests_stub = mock.Mock()
    requests_stub.exceptions.RequestException = Exception
    with mock.patch.object(runner, "WG_CONF_PATH", conf_path):
        with mock.patch.object(runner, "get_credentials", return_value=("TOK", "SEC")):
            with mock.patch.object(runner, "generate_wireguard_keys", return_value=(SAMPLE_PRIV, SAMPLE_PUB)):
                with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
                    with mock.patch.object(runner, "load_requests", return_value=requests_stub):
                        with mock.patch.object(runner, "api_get", return_value=_native_success_response()) as api_mock:
                            with mock.patch.object(runner, "system_binary", return_value="/usr/bin/wg-quick"):
                                with mock.patch.object(runner, "run_bounded", side_effect=bounded):
                                    result = runner.connect("PT", "traffic")

    assert result["backend"] == "wireguard"
    assert result["country"] == "PT"
    with open(conf_path, encoding="utf-8") as config_file:
        config_text = config_file.read()
    assert "AllowedIPs = 0.0.0.0/0, ::/0" in config_text
    assert api_mock.call_args.kwargs["timeout"][0] <= 3.5
    os.unlink(conf_path)
    os.rmdir(d)


def test_connect_retries_without_dns_when_resolvconf_fails():
    d = tempfile.mkdtemp()
    conf_path = os.path.join(d, "cyberghost.conf")
    calls = []

    def bounded(command, **kwargs):
        calls.append(command)
        if command[1] == "up" and calls.count(command) == 1:
            return runner.subprocess.CompletedProcess(command, 1, "", "resolvconf: command failed")
        if command[1] == "up":
            return runner.subprocess.CompletedProcess(command, 0, "interface up", "")
        return runner.subprocess.CompletedProcess(command, 1, "", "not found")

    requests_stub = mock.Mock()
    requests_stub.exceptions.RequestException = Exception
    with mock.patch.object(runner, "WG_CONF_PATH", conf_path):
        with mock.patch.object(runner, "get_credentials", return_value=("TOK", "SEC")):
            with mock.patch.object(runner, "generate_wireguard_keys", return_value=(SAMPLE_PRIV, SAMPLE_PUB)):
                with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
                    with mock.patch.object(runner, "load_requests", return_value=requests_stub):
                        with mock.patch.object(runner, "api_get", return_value=_native_success_response()):
                            with mock.patch.object(runner, "system_binary", return_value="/usr/bin/wg-quick"):
                                with mock.patch.object(runner, "run_bounded", side_effect=bounded):
                                    runner.connect("PT", "traffic")

    with open(conf_path, encoding="utf-8") as config_file:
        config_text = config_file.read()
    assert "DNS =" not in config_text
    assert sum(command[1] == "up" for command in calls) == 2
    os.unlink(conf_path)
    os.rmdir(d)


def test_connect_rolls_back_after_tunnel_activation_failure():
    d = tempfile.mkdtemp()
    conf_path = os.path.join(d, "cyberghost.conf")
    calls = []

    def bounded(command, **kwargs):
        calls.append(command)
        if command[1] == "up":
            return runner.subprocess.CompletedProcess(command, 1, "", "wg-quick failed")
        return runner.subprocess.CompletedProcess(command, 1, "", "not found")

    requests_stub = mock.Mock()
    requests_stub.exceptions.RequestException = Exception
    with mock.patch.object(runner, "WG_CONF_PATH", conf_path):
        with mock.patch.object(runner, "get_credentials", return_value=("TOK", "SEC")):
            with mock.patch.object(runner, "generate_wireguard_keys", return_value=(SAMPLE_PRIV, SAMPLE_PUB)):
                with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
                    with mock.patch.object(runner, "load_requests", return_value=requests_stub):
                        with mock.patch.object(runner, "api_get", return_value=_native_success_response()):
                            with mock.patch.object(runner, "system_binary", return_value="/usr/bin/wg-quick"):
                                with mock.patch.object(runner, "run_bounded", side_effect=bounded):
                                    try:
                                        runner.connect("PT", "traffic")
                                        raise AssertionError("Expected tunnel activation failure")
                                    except RuntimeError as exc:
                                        assert "wg-quick up failed" in str(exc)

    assert sum(command[1] == "down" for command in calls) == 2
    os.unlink(conf_path)
    os.rmdir(d)


def test_register_uses_api_response_and_never_persists_password():
    d = tempfile.mkdtemp()
    config_path = os.path.join(d, "config.ini")

    def response(status_code, body):
        item = mock.Mock(status_code=status_code)
        item._cyberghost_body = json.dumps(body).encode()
        return item

    with mock.patch.dict(os.environ, {"CG_USERNAME": "user@example.com", "CG_PASSWORD": "secret"}, clear=False):
        with mock.patch.object(runner, "user_config_path", return_value=config_path):
            with mock.patch.object(runner.socket, "gethostname", return_value="test-host"):
                with mock.patch.object(
                    runner,
                    "api_request",
                    side_effect=[
                        response(200, {"jwt": "jwt-token"}),
                        response(201, {"name": "test-host", "token": "TOK", "tokenSecret": "SEC"}),
                    ],
                ):
                    runner.register()

    cfg = configparser.ConfigParser()
    cfg.read(config_path)
    assert cfg.get("account", "username") == "user@example.com"
    assert not cfg.has_option("account", "password")
    assert cfg.get("device", "secret") == "SEC"
    # register() must scrub the env vars it consumed so they cannot leak
    # into a later subprocess or a captured traceback.
    assert "CG_USERNAME" not in os.environ
    assert "CG_PASSWORD" not in os.environ
    os.unlink(config_path)
    os.rmdir(d)


def test_register_scrubs_env_vars_even_when_api_fails():
    """register() must clear CG_USERNAME/CG_PASSWORD from os.environ even if the API call raises."""

    def response(status_code, body):
        item = mock.Mock(status_code=status_code)
        item._cyberghost_body = json.dumps(body).encode()
        return item

    env = {"CG_USERNAME": "user@example.com", "CG_PASSWORD": "secret"}
    with mock.patch.dict(os.environ, env, clear=False):
        with mock.patch.object(runner, "user_config_path", return_value="/tmp/cyberghost-scrub-test.ini"):
            with mock.patch.object(runner.socket, "gethostname", return_value="test-host"):
                with mock.patch.object(
                    runner,
                    "api_request",
                    side_effect=RuntimeError("network down"),
                ):
                    try:
                        runner.register()
                    except RuntimeError:
                        pass

    # The env vars must be gone whether register() succeeded or raised.
    assert "CG_USERNAME" not in os.environ
    assert "CG_PASSWORD" not in os.environ


def test_helper_version_and_capability_are_verified():
    helper = tempfile.NamedTemporaryFile(mode="wb", delete=False)
    helper.write(f'PLUGIN_VERSION = "{runner.PLUGIN_VERSION}"\n'.encode() + b'HELPER_CAPABILITY_VERSION = "5"\n')
    helper.close()
    with mock.patch.object(runner, "HELPER_BIN_PATH", helper.name):
        with mock.patch.object(runner, "secure_system_file", return_value=True):
            assert runner.installed_helper_version() == runner.PLUGIN_VERSION
            assert runner.secure_helper_installed() is True
            with mock.patch.object(runner, "PLUGIN_VERSION", "1.4.4"):
                assert runner.secure_helper_installed() is False
    os.unlink(helper.name)


def test_main_emits_structured_json_action_result():
    import io
    from contextlib import redirect_stdout

    original_argv = runner.sys.argv
    buf = io.StringIO()
    try:
        runner.sys.argv = ["cyberghost_runner.py", "connect", "--json", "--country", "PT"]
        with mock.patch.object(runner, "connect", return_value={"backend": "wireguard", "country": "PT"}):
            with redirect_stdout(buf):
                runner.main()
    finally:
        runner.sys.argv = original_argv

    result = json.loads(buf.getvalue())
    assert result["ok"] is True
    assert result["action"] == "connect"
    assert result["backend"] == "wireguard"


def test_main_emits_structured_json_disconnect_result():
    import io
    from contextlib import redirect_stdout

    original_argv = runner.sys.argv
    buf = io.StringIO()
    try:
        runner.sys.argv = ["cyberghost_runner.py", "disconnect", "--json"]
        with mock.patch.object(runner, "disconnect", return_value={"backend": "wireguard", "connected": False}):
            with redirect_stdout(buf):
                runner.main()
    finally:
        runner.sys.argv = original_argv

    result = json.loads(buf.getvalue())
    assert result == {"ok": True, "action": "disconnect", "backend": "wireguard", "connected": False}


def test_main_emits_structured_json_action_error():
    import io
    from contextlib import redirect_stdout

    original_argv = runner.sys.argv
    buf = io.StringIO()
    try:
        runner.sys.argv = ["cyberghost_runner.py", "disconnect", "--json"]
        with mock.patch.object(runner, "disconnect", side_effect=RuntimeError("helper unavailable")):
            try:
                with redirect_stdout(buf):
                    runner.main()
                raise AssertionError("Expected main to exit nonzero")
            except SystemExit as exc:
                assert exc.code == 1
    finally:
        runner.sys.argv = original_argv

    result = json.loads(buf.getvalue())
    assert result == {"ok": False, "action": "disconnect", "error": "helper unavailable"}


def test_ui_contract_uses_json_actions_and_separate_streaming_stderr():
    service = (ROOT / "Service.qml").read_text()
    assert '"--json"' in service
    assert '"--no-cli"' in service
    assert 'import "ServiceUtils.js" as ServiceUtils' in service
    assert "streamingServicesErrorOutput" in service
    assert "extractCleanError" not in service
    assert "connectedSince" not in service
    assert "polkitError" not in service
    assert "userName" not in service
    assert service.index("savedServerSelection") < service.index("setServerSelection(savedServerSelection)")
    assert "root.appendBounded" not in service


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except Exception as exc:
                failed += 1
                print(f"FAIL {name}: {exc}")
    sys.exit(1 if failed else 0)

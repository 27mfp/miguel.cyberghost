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
            assert False, f"Expected ValueError for invalid key: {ik!r}"
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
            assert False, f"Expected ValueError for invalid IP: {ip!r}"
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
            assert False, f"Expected ValueError for invalid port: {p!r}"
        except (ValueError, TypeError):
            pass


def test_validate_country_code():
    assert runner.validate_country_code("pt") == "PT"
    assert runner.validate_country_code(" US ") == "US"
    for code in ("P!", "PT1", "P", "", None):
        try:
            runner.validate_country_code(code)
            assert False, f"Expected ValueError for invalid country code: {code!r}"
        except (ValueError, TypeError):
            pass


def test_validate_server_selector():
    assert runner.validate_server_selector("Lisbon-s405-i19") == "lisbon-s405-i19"
    for server in ("50", "lisbon-s50", "lisbon-s405-i19.cg-dialup.net", "lisbon s405 i19", "", None):
        try:
            runner.validate_server_selector(server)
            assert False, f"Expected ValueError for invalid server: {server!r}"
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
            assert False, f"Expected ValueError for invalid streaming service: {service!r}"
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
            assert False, f"Expected ValueError for invalid host: {h!r}"
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
        assert False, "Expected ValueError for injected DNS"
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
        assert False, "Expected ValueError for injected private key"
    except ValueError:
        pass

    ipv6_cfg = runner.build_wg_config(SAMPLE_PRIV, "10.2.0.2", SAMPLE_PUB, "2001:db8::1", 1337)
    assert "Endpoint = [2001:db8::1]:1337" in ipv6_cfg

    ipv6_peer_cfg = runner.build_wg_config(SAMPLE_PRIV, "2001:db8::2", SAMPLE_PUB, "1.2.3.4", 1337)
    assert "Address = 2001:db8::2/128" in ipv6_peer_cfg

    try:
        runner.build_wg_config(SAMPLE_PRIV, "10.2.0.2\nPreUp = touch /tmp/pwned", SAMPLE_PUB, "1.2.3.4", 1337)
        assert False, "Expected ValueError for injected peer IP"
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
        assert False, "Expected RuntimeError when loading config from symlink"
    except RuntimeError as e:
        assert "symlink" in str(e).lower()




def test_check_output_shape():
    import io
    from contextlib import redirect_stdout

    buf = io.StringIO()
    with redirect_stdout(buf):
        runner.check()
    data = json.loads(buf.getvalue())
    expected_keys = {"wg_tools", "requests", "cli", "credentials", "helper_installed", "polkit_rule_installed"}
    assert set(data) == expected_keys
    for value in data.values():
        assert isinstance(value, bool)


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
        path, "user@example.com", "pw", "omarchy",
        {"name": "", "token": "TOK", "tokenSecret": "SEC"},
    )
    cfg = configparser.ConfigParser()
    cfg.read(path)
    assert cfg.get("account", "username") == "user@example.com"
    assert not cfg.has_option("account", "password")
    assert cfg.get("device", "name") == "omarchy"          # falls back to device_name
    assert cfg.get("device", "token") == "TOK"
    assert cfg.get("device", "secret") == "SEC"            # tokenSecret -> secret
    assert not (os.stat(path).st_mode & 0o077)             # owner-only permissions


def test_run_bounded_rejects_excessive_output():
    try:
        runner.run_bounded(
            [sys.executable, "-c", "print('x' * 256)"],
            timeout=5,
            max_output_bytes=64,
        )
        assert False, "Expected output limit to terminate the command"
    except RuntimeError as exc:
        assert "output exceeded" in str(exc)


def test_cli_environment_uses_pkexec_initiating_user_home():
    initiating_user = mock.Mock(pw_dir="/home/miguel", pw_name="miguel")
    with mock.patch.object(runner.os, "geteuid", return_value=0):
        with mock.patch.dict(runner.os.environ, {"PKEXEC_UID": "1000"}, clear=False):
            with mock.patch.object(runner, "invoking_user", return_value=initiating_user):
                env = runner.cyberghost_cli_environment()

    assert env["HOME"] == "/home/miguel"
    assert env["USER"] == "miguel"
    assert env["LOGNAME"] == "miguel"


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

        completed_empty = runner.subprocess.CompletedProcess([], 0, "", "")
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
                            assert False, "Expected the native API failure to be reported"
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
        assert False, "Expected RuntimeError for oversized config"
    except RuntimeError as e:
        assert "exceeds maximum size" in str(e)


def test_manifest_schema_and_validity():
    manifest_path = ROOT / "manifest.json"
    assert manifest_path.is_file()
    data = json.loads(manifest_path.read_text())

    assert data.get("id") == "miguel.cyberghost"
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
    with redirect_stdout(buf):
        runner.status(as_json=True)
    out = json.loads(buf.getvalue())
    assert "connected" in out
    assert isinstance(out["connected"], bool)
    assert "interface" in out


def test_root_helper_rejects_non_lifecycle_actions():
    original_argv = runner.sys.argv
    try:
        runner.sys.argv = [runner.HELPER_BIN_PATH, "register"]
        with mock.patch.object(runner, "installed_helper_invocation", return_value=True):
            args = mock.Mock(action="register", config=None, city=None, json=False)
            try:
                runner.validate_helper_request(args)
                assert False, "Expected the installed helper to reject register"
            except RuntimeError as exc:
                assert "only supports connect and disconnect" in str(exc)
    finally:
        runner.sys.argv = original_argv


def test_root_helper_rejects_custom_config():
    with mock.patch.object(runner, "installed_helper_invocation", return_value=True):
        args = mock.Mock(action="connect", config="/tmp/other.ini", city=None, json=False)
        try:
            runner.validate_helper_request(args)
            assert False, "Expected the installed helper to reject a custom config"
        except RuntimeError as exc:
            assert "custom paths" in str(exc)


def test_ui_privilege_boundary_contract():
    service = (ROOT / "Service.qml").read_text()
    assert '["pkexec", root.helperPath]' in service
    assert '"pkexec", "/usr/bin/install"' not in service
    assert "install-helper.sh" in service
    assert "pkexec\", \"/usr/bin/python3\"" not in service
    assert "pkexec\", \"sh\"" not in service
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

"""Backend contracts regression tests."""

import json
import os
import pathlib
import tempfile
from unittest import mock

from runner_support import ROOT, load_runner

runner = load_runner()


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


def test_main_rejects_non_wireguard_modes_without_starting_a_backend():
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
                try:
                    runner.main()
                    raise AssertionError("Unsupported mode was accepted")
                except SystemExit as exc:
                    assert exc.code == 1
        cli_mock.assert_not_called()
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


def test_manifest_schema_and_validity():
    manifest_path = ROOT / "manifest.json"
    assert manifest_path.is_file()
    data = json.loads(manifest_path.read_text())

    assert data.get("id") == "miguel.cyberghost"
    assert data.get("version") == runner.PLUGIN_VERSION
    assert data.get("entryPoints", {}).get("barWidget") == "BarWidget.qml"
    assert data["kinds"] == ["bar-widget"]
    for entry in data["entryPoints"].values():
        assert (ROOT / entry).is_file()
    assert data.get("barWidget", {}).get("description")
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


def test_root_helper_skips_optional_vendor_inventory():
    with mock.patch.object(runner.os, "geteuid", return_value=0):
        with mock.patch.object(
            runner, "get_servers_for_country", side_effect=AssertionError("vendor CLI must not run as root")
        ):
            country, candidates = runner.select_native_candidates("PT", "traffic")
    assert country == "PT"
    assert candidates


def test_wireguard_config_symlink_is_rejected_before_cleanup():
    directory = pathlib.Path(tempfile.mkdtemp())
    target = directory / "real.conf"
    target.write_text("[Interface]\n", encoding="utf-8")
    link = directory / "cyberghost.conf"
    link.symlink_to(target)
    with mock.patch.object(runner, "WG_CONF_PATH", str(link)):
        try:
            runner.secure_wireguard_config()
            raise AssertionError("config symlink must be rejected")
        except RuntimeError as exc:
            assert "symlink" in str(exc)
    link.unlink()
    target.unlink()
    directory.rmdir()


def test_root_helper_rejects_custom_config():
    with mock.patch.object(runner, "installed_helper_invocation", return_value=True):
        args = mock.Mock(
            action="connect",
            config="/tmp/other.ini",
            city=None,
            json=False,
            protocol="wireguard",
            server_type="traffic",
            streaming_service=None,
        )
        try:
            runner.validate_helper_request(args)
            raise AssertionError("Expected the installed helper to reject a custom config")
        except RuntimeError as exc:
            assert "custom paths" in str(exc)


def test_ui_privilege_boundary_contract():
    # Inspect every production component: moving code must not evade this guard.
    service = "\n".join(path.read_text() for path in ROOT.glob("*.qml"))
    assert '["/usr/bin/pkexec", root.helperPath]' in service
    assert '"pkexec", "/usr/bin/install"' not in service
    assert "install-helper.sh" in service
    assert 'pkexec", "/usr/bin/python3"' not in service
    assert 'pkexec", "sh"' not in service
    assert "StdioCollector" not in service
    assert '"CG_PASSWORD"' not in service
    assert '"servers"' in (ROOT / "ServerInventory.qml").read_text()
    assert '"--server"' in service
    assert "https://ipwho.is/?type=ipv4" in service
    # The plain (no-params) URL must not reappear — that path returns IPv6
    # on most hosts today, which is rarely what the user wants to see.
    assert 'https://ipwho.is/"' not in service
    assert "https://ipwho.is/," not in service

    runner_source = (ROOT / "cyberghost_runner.py").read_text()
    assert 'HELPER_CAPABILITY_VERSION = "8"' in runner_source


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
    # mkdir without -p: a pre-created /tmp path must abort, not be reused.
    assert 'mkdir -m 0700 -- "$ROOT_STAGE_DIR"' in installer
    assert "mkdir -m 0700 -p" not in installer
    assert "Refusing to reuse an existing staging path" in installer


def test_helper_version_and_capability_are_verified():
    helper = tempfile.NamedTemporaryFile(mode="wb", delete=False)
    helper.write(
        (
            f'PLUGIN_VERSION = "{runner.PLUGIN_VERSION}"\n'
            f'HELPER_CAPABILITY_VERSION = "{runner.HELPER_CAPABILITY_VERSION}"\n'
        ).encode()
    )
    helper.close()
    with mock.patch.object(runner, "HELPER_BIN_PATH", helper.name):
        with mock.patch.object(runner, "secure_system_file", return_value=True):
            assert runner.installed_helper_version() == runner.PLUGIN_VERSION
            assert runner.secure_helper_installed() is True
            # Patching to a deliberately-bogus version proves the helper is
            # rejected when the on-disk version does not match the bundled
            # PLUGIN_VERSION (the same check that powers the
            # `helperNeedsUpdate` drift detector in Service.qml).
            with mock.patch.object(runner, "PLUGIN_VERSION", "0.0.0-drift"):
                assert runner.secure_helper_installed() is False
            pathlib.Path(helper.name).write_text(
                f'PLUGIN_VERSION = "{runner.PLUGIN_VERSION}"\nHELPER_CAPABILITY_VERSION = "6"\n'
            )
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
    assert "ServiceUtils.parseActionResult" in service

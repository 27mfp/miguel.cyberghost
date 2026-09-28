"""Backend contracts regression tests."""

import json
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
        with mock.patch.object(runner, "connect") as native_mock:
            runner.main()
        native_mock.assert_called_once_with("PT", "traffic", None, None, None)
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
        with mock.patch.object(runner, "connect") as native_mock:
            try:
                runner.main()
                raise AssertionError("Unsupported mode was accepted")
            except SystemExit as exc:
                assert exc.code == 1
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


def test_main_emits_structured_json_action_result():
    import io
    from contextlib import redirect_stdout

    original_argv = runner.sys.argv
    buf = io.StringIO()
    try:
        runner.sys.argv = ["cyberghost_runner.py", "connect", "--json", "--country", "PT"]
        with mock.patch.object(runner, "connect", return_value={"backend": "networkmanager", "country": "PT"}):
            with redirect_stdout(buf):
                runner.main()
    finally:
        runner.sys.argv = original_argv

    result = json.loads(buf.getvalue())
    assert result["ok"] is True
    assert result["action"] == "connect"
    assert result["backend"] == "networkmanager"


def test_main_emits_structured_json_disconnect_result():
    import io
    from contextlib import redirect_stdout

    original_argv = runner.sys.argv
    buf = io.StringIO()
    try:
        runner.sys.argv = ["cyberghost_runner.py", "disconnect", "--json"]
        with mock.patch.object(runner, "disconnect", return_value={"backend": "networkmanager", "connected": False}):
            with redirect_stdout(buf):
                runner.main()
    finally:
        runner.sys.argv = original_argv

    result = json.loads(buf.getvalue())
    assert result == {"ok": True, "action": "disconnect", "backend": "networkmanager", "connected": False}


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
    assert result == {"ok": False, "action": "disconnect", "error": "helper unavailable", "code": ""}


def test_main_reports_legacy_tunnel_code_for_the_ui():
    import io
    from contextlib import redirect_stdout

    original_argv = runner.sys.argv
    buf = io.StringIO()
    try:
        runner.sys.argv = ["cyberghost_runner.py", "disconnect", "--json"]
        with mock.patch.object(runner, "disconnect", side_effect=runner.LegacyTunnelError("old tunnel")):
            try:
                with redirect_stdout(buf):
                    runner.main()
                raise AssertionError("Expected main to exit nonzero")
            except SystemExit as exc:
                assert exc.code == 1
    finally:
        runner.sys.argv = original_argv
    assert json.loads(buf.getvalue())["code"] == "legacy_tunnel"


def test_ui_privilege_boundary_contract():
    # Inspect every production component: moving code must not evade this guard.
    qml = "\n".join(path.read_text() for path in ROOT.glob("*.qml"))
    # The only privileged call left is the pre-1.7 helper removing its own tunnel.
    assert qml.count("/usr/bin/pkexec") == 1
    assert '["/usr/bin/pkexec", root.legacyHelperPath, "disconnect", "--json"]' in qml
    assert "/usr/bin/sudo" not in qml and '"sudo"' not in qml
    assert "install-helper.sh" not in qml
    assert '"/usr/bin/python3", root.runnerPath, "connect"' in qml
    assert '"/usr/bin/python3", root.runnerPath, "disconnect", "--json"' in qml
    assert '"/usr/bin/python3", root.runnerPath, "logout", "--json"' in qml
    assert "StdioCollector" not in qml
    assert '"CG_PASSWORD"' not in qml
    assert '"servers"' in (ROOT / "ServerInventory.qml").read_text()
    assert '"--server"' in qml
    # Omarchy's convention for sudo work: a visible floating terminal. The
    # plugin path reaches it through the environment, not the command string.
    assert "omarchy-launch-floating-terminal-with-presentation" in qml
    assert "omarchy-pkg-add python-requests" in qml
    assert '"bash \\"$CYBERGHOST_LEGACY_CLEANUP\\""' in qml
    assert "https://ipwho.is/?type=ipv4" in qml
    # The plain (no-params) URL must not reappear — that path returns IPv6
    # on most hosts today, which is rarely what the user wants to see.
    assert 'https://ipwho.is/"' not in qml
    assert "https://ipwho.is/," not in qml


def test_ui_contract_uses_json_actions_and_separate_streaming_stderr():
    service = (ROOT / "Service.qml").read_text()
    assert '"--json"' in service
    assert '"--no-cli"' not in service
    assert 'import "ServiceUtils.js" as ServiceUtils' in service
    assert "streamingServicesErrorOutput" in service
    assert "ServiceUtils.parseActionResult" in service
    assert 'result.code === "legacy_tunnel"' in service

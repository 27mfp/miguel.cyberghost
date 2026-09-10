"""Backend wireguard regression tests."""

import json
import os
import tempfile
from unittest import mock

from runner_support import SAMPLE_PRIV, SAMPLE_PUB, load_runner, native_success_response

runner = load_runner()


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


def test_disconnect_cleans_native_and_cli_state():
    import io
    from contextlib import redirect_stdout

    interface_up = True

    def bounded(command, **kwargs):
        nonlocal interface_up
        if command[1:3] == ["link", "show"]:
            if interface_up:
                return runner.subprocess.CompletedProcess(command, 0, "3: cyberghost: <POINTOPOINT>\n", "")
            return runner.subprocess.CompletedProcess(command, 1, "", 'Device "cyberghost" does not exist.')
        if command[1:4] == ["route", "show", "table"] or command[1:3] == ["rule", "show"]:
            return runner.subprocess.CompletedProcess(command, 0, "", "")
        if command[1] == "-l":
            return runner.subprocess.CompletedProcess(command, 1, "", "not found")
        if command[1:3] == ["link", "delete"]:
            interface_up = False
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


def test_connect_rejects_explicit_empty_dns_before_lifecycle_commands():
    response = native_success_response(runner)
    body = json.loads(response._cyberghost_body)
    body["dns_servers"] = []
    response._cyberghost_body = json.dumps(body).encode()
    with mock.patch.object(runner, "get_credentials", return_value=("TOK", "SEC")):
        with mock.patch.object(runner, "generate_wireguard_keys", return_value=(SAMPLE_PRIV, SAMPLE_PUB)):
            with mock.patch.object(
                runner, "select_native_candidates", return_value=("PT", ["lisbon-s405.cg-dialup.net"])
            ):
                with mock.patch.object(
                    runner, "exchange_wireguard_key", return_value=(body, "lisbon-s405.cg-dialup.net")
                ):
                    with mock.patch.object(
                        runner, "system_binary", side_effect=AssertionError("lifecycle must not start")
                    ):
                        try:
                            runner.connect("PT", "traffic")
                            raise AssertionError("explicit empty DNS must fail")
                        except ValueError as exc:
                            assert "DNS" in str(exc)


def test_cleanup_reports_residual_interface_and_policy_state():
    def bounded(command, **kwargs):
        if command[1:3] == ["link", "show"]:
            return runner.subprocess.CompletedProcess(command, 0, "3: cyberghost: <POINTOPOINT>\n", "")
        if command[1:4] == ["route", "show", "table"]:
            return runner.subprocess.CompletedProcess(command, 0, "default dev cyberghost table 51820\n", "")
        if command[1:3] == ["rule", "show"]:
            return runner.subprocess.CompletedProcess(command, 0, "32765: not from all lookup 51820\n", "")
        if command[1] == "-l":
            return runner.subprocess.CompletedProcess(command, 0, "DNS=1.1.1.1\n", "")
        return runner.subprocess.CompletedProcess(command, 0, "", "")

    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/ip"):
        with mock.patch.object(runner, "run_bounded", side_effect=bounded):
            problems = runner.cleanup_wireguard_state("/usr/bin/wg-quick", "/usr/bin/ip", config_present=True)
    assert any("still present" in problem for problem in problems)
    assert any("policy route" in problem for problem in problems)
    assert any("policy rules" in problem for problem in problems)
    assert any("resolver" in problem for problem in problems)


def test_connect_writes_and_activates_native_tunnel():
    d = tempfile.mkdtemp()
    conf_path = os.path.join(d, "cyberghost.conf")

    interface_up = False

    def bounded(command, **kwargs):
        nonlocal interface_up
        if command[1] == "up":
            interface_up = True
            return runner.subprocess.CompletedProcess(command, 0, "interface up", "")
        if command[1:3] == ["link", "show"]:
            if interface_up:
                return runner.subprocess.CompletedProcess(command, 0, "3: cyberghost: <POINTOPOINT>\n", "")
            return runner.subprocess.CompletedProcess(command, 1, "", 'Device "cyberghost" does not exist.')
        if command[1:4] == ["route", "show", "table"] or command[1:3] == ["rule", "show"]:
            return runner.subprocess.CompletedProcess(command, 0, "", "")
        if command[1] == "-l":
            return runner.subprocess.CompletedProcess(command, 1, "", "not found")
        if command[1:3] == ["link", "delete"]:
            interface_up = False
        return runner.subprocess.CompletedProcess(command, 0, "", "")

    requests_stub = mock.Mock()
    requests_stub.exceptions.RequestException = Exception
    with mock.patch.object(runner, "WG_CONF_PATH", conf_path):
        with mock.patch.object(runner, "get_credentials", return_value=("TOK", "SEC")):
            with mock.patch.object(runner, "generate_wireguard_keys", return_value=(SAMPLE_PRIV, SAMPLE_PUB)):
                with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
                    with mock.patch.object(runner, "load_requests", return_value=requests_stub):
                        with mock.patch.object(
                            runner, "api_get", return_value=native_success_response(runner)
                        ) as api_mock:
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


def test_connect_fails_closed_when_vpn_dns_cannot_be_configured():
    d = tempfile.mkdtemp()
    conf_path = os.path.join(d, "cyberghost.conf")
    calls = []

    interface_up = False
    up_attempts = 0

    def bounded(command, **kwargs):
        nonlocal interface_up, up_attempts
        calls.append(command)
        if command[1] == "up":
            up_attempts += 1
            if up_attempts == 1:
                return runner.subprocess.CompletedProcess(command, 1, "", "resolvconf: command failed")
            interface_up = True
            return runner.subprocess.CompletedProcess(command, 0, "interface up", "")
        if command[1:3] == ["link", "show"]:
            if interface_up:
                return runner.subprocess.CompletedProcess(command, 0, "3: cyberghost: <POINTOPOINT>\n", "")
            return runner.subprocess.CompletedProcess(command, 1, "", 'Device "cyberghost" does not exist.')
        if command[1:4] == ["route", "show", "table"] or command[1:3] == ["rule", "show"]:
            return runner.subprocess.CompletedProcess(command, 0, "", "")
        if command[1] == "-l":
            return runner.subprocess.CompletedProcess(command, 1, "", "not found")
        if command[1:3] == ["link", "delete"]:
            interface_up = False
        return runner.subprocess.CompletedProcess(command, 0, "", "")

    requests_stub = mock.Mock()
    requests_stub.exceptions.RequestException = Exception
    with mock.patch.object(runner, "WG_CONF_PATH", conf_path):
        with mock.patch.object(runner, "get_credentials", return_value=("TOK", "SEC")):
            with mock.patch.object(runner, "generate_wireguard_keys", return_value=(SAMPLE_PRIV, SAMPLE_PUB)):
                with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
                    with mock.patch.object(runner, "load_requests", return_value=requests_stub):
                        with mock.patch.object(runner, "api_get", return_value=native_success_response(runner)):
                            with mock.patch.object(runner, "system_binary", return_value="/usr/bin/wg-quick"):
                                with mock.patch.object(runner, "run_bounded", side_effect=bounded):
                                    try:
                                        runner.connect("PT", "traffic")
                                        raise AssertionError("DNS failure must not report connection success")
                                    except RuntimeError as exc:
                                        assert "DNS" in str(exc)

    assert not os.path.exists(conf_path)
    assert sum(command[1] == "up" for command in calls) == 1
    assert sum(command[1] == "down" for command in calls) >= 2
    os.rmdir(d)


def test_connect_rolls_back_after_tunnel_activation_failure():
    d = tempfile.mkdtemp()
    conf_path = os.path.join(d, "cyberghost.conf")
    calls = []

    interface_up = False

    def bounded(command, **kwargs):
        nonlocal interface_up
        calls.append(command)
        if command[1] == "up":
            return runner.subprocess.CompletedProcess(command, 1, "", "wg-quick failed")
        if command[1:3] == ["link", "show"]:
            return runner.subprocess.CompletedProcess(command, 1, "", 'Device "cyberghost" does not exist.')
        if command[1:4] == ["route", "show", "table"] or command[1:3] == ["rule", "show"]:
            return runner.subprocess.CompletedProcess(command, 0, "", "")
        if command[1] == "-l":
            return runner.subprocess.CompletedProcess(command, 1, "", "not found")
        if command[1:3] == ["link", "delete"]:
            interface_up = False
        return runner.subprocess.CompletedProcess(command, 0, "", "")

    requests_stub = mock.Mock()
    requests_stub.exceptions.RequestException = Exception
    with mock.patch.object(runner, "WG_CONF_PATH", conf_path):
        with mock.patch.object(runner, "get_credentials", return_value=("TOK", "SEC")):
            with mock.patch.object(runner, "generate_wireguard_keys", return_value=(SAMPLE_PRIV, SAMPLE_PUB)):
                with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
                    with mock.patch.object(runner, "load_requests", return_value=requests_stub):
                        with mock.patch.object(runner, "api_get", return_value=native_success_response(runner)):
                            with mock.patch.object(runner, "system_binary", return_value="/usr/bin/wg-quick"):
                                with mock.patch.object(runner, "run_bounded", side_effect=bounded):
                                    try:
                                        runner.connect("PT", "traffic")
                                        raise AssertionError("Expected tunnel activation failure")
                                    except RuntimeError as exc:
                                        assert "wg-quick up failed" in str(exc)

    assert sum(command[1] == "down" for command in calls) >= 2
    assert not os.path.exists(conf_path)
    os.rmdir(d)

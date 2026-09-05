"""Backend vendor regression tests."""

from unittest import mock

from runner_support import load_runner

runner = load_runner()


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


def test_cli_crash_reports_account_recovery_instead_of_bootloader_footer():
    error = (
        "Traceback (most recent call last):\n"
        '  File "libs/config.py", line 96, in getConfig\n'
        'Exception: The key "password" does not exist in section "account"!\n'
        "[461047] Failed to execute script 'cyberghostvpn' due to unhandled exception!\n"
    )
    message = runner.clean_command_error(error)
    assert "cyberghostvpn --setup" in message
    assert "461047" not in message
    assert "Traceback" not in message


def test_cli_crash_footer_preserves_underlying_error():
    assert (
        runner.clean_command_error(
            "ConnectionError: Service unavailable\n"
            "[123] Failed to execute script 'cyberghostvpn' due to unhandled exception!"
        )
        == "ConnectionError: Service unavailable"
    )
    assert (
        runner.clean_command_error(
            "[123] Failed to execute script 'cyberghostvpn' due to unhandled exception!", "Unavailable"
        )
        == "Unavailable"
    )


def test_server_inventory_filters_duplicates_and_invalid_loads():
    table = (
        "| 1 | Lisbon | lisbon-s405-i19 | 18% |\n"
        "| 2 | Lisbon | lisbon-s405-i19 | 18% |\n"
        "| 3 | Lisbon | lisbon-s405-i20 | 101% |\n"
    )
    completed = runner.subprocess.CompletedProcess([], 0, table, "")
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/cyberghostvpn"):
        with mock.patch.object(runner, "run_bounded", return_value=completed):
            servers = runner.get_servers_for_country("PT")
    assert len(servers) == 1
    assert servers[0]["server"] == "lisbon-s405-i19"


def test_server_inventory_reports_unparseable_success(capsys):
    completed = runner.subprocess.CompletedProcess([], 0, "Unexpected vendor response", "")
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/cyberghostvpn"):
        with mock.patch.object(runner, "run_bounded", return_value=completed):
            assert runner.get_servers_for_country("PT") == []
    assert "No selectable servers" in capsys.readouterr().err


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


def test_clean_command_error_drops_partial_traceback():
    raw = 'Traceback (most recent call last):\n  File "cyberghost_runner.py", line 738\n    r = api_get(url)'
    assert runner.clean_command_error(raw, "Try again") == "Try again"

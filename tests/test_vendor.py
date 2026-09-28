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


def test_server_inventory_reports_expected_failures_to_stderr():
    import io
    from contextlib import redirect_stderr

    error = io.StringIO()
    with mock.patch.object(runner, "system_binary", side_effect=RuntimeError("CLI unavailable")):
        with redirect_stderr(error):
            assert runner.get_servers_for_country("PT") == []
    assert "Server inventory unavailable for PT" in error.getvalue()
    assert "CLI unavailable" in error.getvalue()


def test_streaming_service_discovery():
    table = (
        "+-----+-----------------------+--------------+\n"
        "| No. |        Service        | Country Code |\n"
        "+-----+-----------------------+--------------+\n"
        "|  1  |       Netflix US      |      US      |\n"
        "|  2  |       Netflix DE      |      DE      |\n"
    )
    completed = runner.subprocess.CompletedProcess(["cyberghostvpn"], 0, table, "")
    with mock.patch.object(runner, "system_binary", return_value="/usr/bin/cyberghostvpn"):
        with mock.patch.object(runner, "run_bounded", return_value=completed):
            services = runner.get_streaming_services("US")
            assert services == [{"value": "Netflix US", "label": "Netflix US"}]


def test_clean_command_error_drops_partial_traceback():
    raw = 'Traceback (most recent call last):\n  File "cyberghost_runner.py", line 738\n    r = api_get(url)'
    assert runner.clean_command_error(raw, "Try again") == "Try again"

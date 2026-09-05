"""Failure paths must clean up rather than silently downgrade protection."""

from unittest import mock

import pytest
from runner_support import load_runner

runner = load_runner()


@pytest.mark.parametrize(
    "failure", [TimeoutError("late"), RuntimeError("output exceeded limit"), OSError("spawn failed")]
)
def test_activation_failure_always_attempts_cleanup(failure):
    calls = []

    def execute(command, **kwargs):
        calls.append(command)
        if command[1] == "up":
            raise failure
        return runner.subprocess.CompletedProcess(command, 0, "", "")

    with mock.patch.object(runner, "run_bounded", side_effect=execute):
        with pytest.raises(type(failure)):
            runner.activate_wireguard("/usr/bin/wg-quick", runner.time.monotonic() + 10)
    assert [command[1] for command in calls] == ["up", "down"]


def test_expired_activation_does_not_start_interface():
    with mock.patch.object(runner, "run_bounded") as execute:
        with pytest.raises(RuntimeError, match="timed out"):
            runner.activate_wireguard("/usr/bin/wg-quick", runner.time.monotonic() - 1)
    execute.assert_not_called()

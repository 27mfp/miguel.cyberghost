"""Release boundaries apply even with a fully configured vendor CLI."""

from types import SimpleNamespace
from unittest import mock

import pytest
from runner_support import load_runner

runner = load_runner()


@pytest.mark.parametrize("installed", [False, True])
@pytest.mark.parametrize(
    "protocol,mode,profile",
    [
        ("openvpn", "traffic", None),
        ("openvpn_tcp", "traffic", None),
        ("wireguard", "torrent", None),
        ("wireguard", "streaming", "Netflix"),
    ],
)
def test_unsupported_connection_rejected_before_backend_dispatch(installed, protocol, mode, profile):
    args = SimpleNamespace(action="connect", protocol=protocol, server_type=mode, streaming_service=profile)
    with mock.patch.object(runner, "installed_helper_invocation", return_value=installed):
        with pytest.raises(RuntimeError, match="native WireGuard"):
            runner.validate_helper_request(args)


def test_disconnected_native_helper_does_not_stop_separate_vendor_vpn():
    absent = runner.subprocess.CompletedProcess([], 1, "", "No such device")
    with mock.patch.object(runner, "system_binary", side_effect=lambda name: "/usr/bin/" + name):
        with mock.patch.object(runner, "run_bounded", return_value=absent) as command:
            with mock.patch.object(runner.os.path, "exists", return_value=False):
                with mock.patch.object(runner, "stop_cli_connection") as vendor:
                    assert runner.disconnect() == {"backend": "wireguard", "connected": False}
    vendor.assert_not_called()
    assert all("cyberghostvpn" not in call.args[0][0] for call in command.call_args_list)

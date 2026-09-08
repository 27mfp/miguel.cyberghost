"""The compatibility launcher must not modify unrelated OpenVPN arguments."""

import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/openvpn-compat.sh"
VENDOR = ["--remote", "example.cg-dialup.net", "443", "--auth-user-pass", "/home/example/.cyberghost/openvpn/auth"]


def filtered(arguments):
    result = subprocess.run(  # noqa: S603 - static shell program, argument values passed separately
        [
            "/usr/bin/bash",
            "-c",
            'source "$1"; shift; filter_openvpn_arguments "$@"; printf "%s\\0" "${OPENVPN_ARGUMENTS[@]}"',
            "test",
            str(SCRIPT),
            *arguments,
        ],
        capture_output=True,
        check=True,
    )
    return result.stdout.decode().rstrip("\0").split("\0")


def test_only_retired_vendor_option_is_removed():
    args = VENDOR + ["--ncp-disable", "--cipher", "AES-256-CBC", "--tls-version-min", "1.2"]
    assert filtered(args) == [value for value in args if value != "--ncp-disable"]


@pytest.mark.parametrize(
    "args",
    [
        ["--ncp-disable", "--version"],
        ["--remote", "example.org", "--auth-user-pass", "/home/example/.cyberghost/openvpn/auth", "--ncp-disable"],
        ["--remote", "example.cg-dialup.net", "--auth-user-pass", "/tmp/auth", "--ncp-disable"],
        VENDOR + ["--ncp-disable=yes"],
        VENDOR + ["--config", "file with spaces;$(no-execution).ovpn"],
    ],
)
def test_unrelated_options_and_boundaries_are_unchanged(args):
    assert filtered(args) == args

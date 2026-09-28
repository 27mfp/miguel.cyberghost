"""Safety contracts for scripts that must not be executed with sudo in tests."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).parents[1]


def test_reset_preserves_vendor_cli_credentials():
    reset = (ROOT / "fresh-install.sh").read_text()
    assert 'rm -rf "$HOME/.cyberghost"' not in reset
    assert 'rm -f -- "$HOME/.cyberghost/native.ini"' in reset
    assert ".connected | type" in reset
    assert 'read -rp "$1 [y/N] " answer || return 1' in reset


def test_install_confirmations_fail_closed_on_eof():
    guided = (ROOT / "install.sh").read_text()
    reset = (ROOT / "fresh-install.sh").read_text()
    assert 'read -rp "$1 [y/N] " answer || return 1' in guided
    assert 'read -rp "$1 [y/N] " answer || return 1' in reset


def test_all_shell_scripts_parse():
    for script in [*ROOT.glob("*.sh"), *ROOT.glob("scripts/*.sh")]:
        subprocess.run(["/usr/bin/bash", "-n", str(script)], check=True)  # noqa: S603 - syntax check, no execution

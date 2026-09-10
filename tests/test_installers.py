"""Safety contracts for scripts that must not be executed with sudo in tests."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).parents[1]


def test_optional_authorization_requires_explicit_opt_in():
    helper = (ROOT / "install-helper.sh").read_text()
    guided = (ROOT / "install.sh").read_text()
    assert "INSTALL_POLKIT=0" in helper
    assert "REVOKE_POLKIT=0" in helper
    assert "--with-polkit-rule) INSTALL_POLKIT=1" in helper
    assert "--revoke-polkit-rule) REVOKE_POLKIT=1" in helper
    assert "existing authorization was preserved" in helper
    assert 'bash "$DIR/install-helper.sh" --with-polkit-rule' in guided
    result = subprocess.run(  # noqa: S603 - fixed repository script, help only
        ["/usr/bin/bash", str(ROOT / "install-helper.sh"), "--help"], capture_output=True, text=True, check=True
    )
    assert "--with-polkit-rule" in result.stdout
    assert "--revoke-polkit-rule" in result.stdout
    assert "prepare_polkit_snapshot" in helper
    assert "__CYBERGHOST_INSTALL_USER__" in (ROOT / "50-cyberghost.rules").read_text()


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

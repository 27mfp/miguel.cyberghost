"""Safety contracts for scripts that must not be executed with sudo in tests."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).parents[1]


def test_optional_authorization_requires_explicit_opt_in():
    helper = (ROOT / "install-helper.sh").read_text()
    guided = (ROOT / "install.sh").read_text()
    assert "INSTALL_POLKIT=0" in helper
    assert "--with-polkit-rule) INSTALL_POLKIT=1" in helper
    assert 'bash "$DIR/install-helper.sh" --with-polkit-rule' in guided
    result = subprocess.run(  # noqa: S603 - fixed repository script, help only
        ["/usr/bin/bash", str(ROOT / "install-helper.sh"), "--help"], capture_output=True, text=True, check=True
    )
    assert "--with-polkit-rule" in result.stdout


def test_reset_preserves_vendor_cli_credentials():
    reset = (ROOT / "fresh-install.sh").read_text()
    assert 'rm -rf "$HOME/.cyberghost"' not in reset
    assert 'rm -f "$HOME/.cyberghost/native.ini"' in reset


def test_all_shell_scripts_parse():
    for script in [*ROOT.glob("*.sh"), *ROOT.glob("scripts/*.sh")]:
        subprocess.run(["/usr/bin/bash", "-n", str(script)], check=True)  # noqa: S603 - syntax check, no execution

"""Safety contracts for scripts that must not be executed with sudo in tests.

The scripts are inspected and exercised in ``--dry-run``/``--help`` modes only;
no package, plugin or credential is changed.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
BASH = shutil.which("bash") or "/usr/bin/bash"


def _run(args, home, timeout=90):
    env = dict(os.environ, HOME=str(home), XDG_CACHE_HOME=str(home / ".cache"))
    return subprocess.run(  # noqa: S603 - repository-owned script, dry-run/help only
        [BASH, str(ROOT / "install.sh"), *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
        check=False,
    )


def test_reset_preserves_vendor_cli_credentials():
    reset = (ROOT / "install.sh").read_text()
    assert 'rm -rf "$HOME/.cyberghost"' not in reset
    assert 'rm -f -- "$HOME/.cyberghost/native.ini"' in reset
    # Tunnel teardown must verify a real boolean, not a missing/falsey field.
    assert "isinstance(connected, bool)" in reset
    assert "missing boolean connected state" in reset
    assert 'read -rp "$1 [y/N] " answer || return 1' in reset


def test_fresh_install_is_a_thin_deprecated_wrapper():
    wrapper = (ROOT / "fresh-install.sh").read_text()
    assert "deprecated" in wrapper.lower()
    assert "install.sh" in wrapper and "--fresh" in wrapper
    # The destructive implementation has a single owner from now on.
    assert "native.ini" not in wrapper
    assert "omarchy plugin" not in wrapper


def test_install_confirmations_fail_closed_on_eof():
    guided = (ROOT / "install.sh").read_text()
    legacy = (ROOT / "scripts/remove-legacy-helper.sh").read_text()
    assert 'read -rp "$1 [y/N] " answer || return 1' in guided
    assert 'read -rp "Continue? [y/N] " answer || answer=""' in legacy
    assert '[[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]' in legacy


def test_help_lists_every_mode_without_side_effects(tmp_path):
    result = _run(["--help"], tmp_path)
    assert result.returncode == 0, result.stderr
    for flag in ("--fresh", "--uninstall", "--dry-run", "--local", "--purge-deps", "--help"):
        assert flag in result.stdout
    assert list(tmp_path.iterdir()) == []


def test_unknown_option_fails_closed(tmp_path):
    result = _run(["--definitely-not-a-flag"], tmp_path)
    assert result.returncode == 1
    assert "unknown option" in result.stderr
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize("mode", [["--dry-run", "--uninstall"], ["--dry-run", "--fresh", "--local"]])
def test_dry_run_plans_without_touching_home(mode, tmp_path):
    result = _run(mode, tmp_path)
    assert result.returncode == 0, result.stderr
    assert "Dry run" in result.stdout
    assert "would" in result.stdout
    # No plugin directory, credentials or cache may be created.
    assert list(tmp_path.iterdir()) == []


def test_dry_run_is_repeatable_without_leaving_state(tmp_path):
    first = _run(["--dry-run", "--uninstall"], tmp_path)
    second = _run(["--dry-run", "--uninstall"], tmp_path)
    assert first.returncode == second.returncode == 0
    assert first.stdout == second.stdout
    assert list(tmp_path.iterdir()) == []


def test_dry_run_purge_deps_does_not_call_pacman(tmp_path):
    result = _run(["--dry-run", "--uninstall", "--purge-deps"], tmp_path)
    assert result.returncode == 0, result.stderr
    assert "would uninstall python-requests" in result.stdout


def test_all_shell_scripts_parse():
    for script in [*ROOT.glob("*.sh"), *ROOT.glob("scripts/*.sh")]:
        subprocess.run(["/usr/bin/bash", "-n", str(script)], check=True)  # noqa: S603 - syntax check, no execution

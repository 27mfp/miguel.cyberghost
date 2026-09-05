"""Credential separation and optional CLI readiness regressions."""

from unittest import mock

import pytest
from runner_support import load_runner

runner = load_runner()


def test_native_registration_storage_does_not_touch_vendor_config(tmp_path):
    vendor = tmp_path / "config.ini"
    vendor.write_text("[account]\nusername=vendor\npassword=keep-me\n")
    native = tmp_path / "native.ini"
    runner.write_user_config(str(native), "native-user", "device", {"token": "TOK", "secret": "SEC"})
    assert "password=keep-me" in vendor.read_text()
    assert "password" not in native.read_text()
    assert native.stat().st_mode & 0o777 == 0o600


def test_legacy_credentials_are_read_without_migration(tmp_path):
    native = tmp_path / "native.ini"
    vendor = tmp_path / "config.ini"
    vendor.write_text("[device]\ntoken=TOK\nsecret=SEC\n")
    vendor.chmod(0o600)
    with mock.patch.object(runner, "user_config_path", return_value=str(native)):
        with mock.patch.object(runner, "legacy_config_path", return_value=str(vendor)):
            assert runner.get_credentials() == ("TOK", "SEC")
    assert not native.exists()


def test_registration_rejects_vendor_path_before_network(tmp_path):
    native = tmp_path / "native.ini"
    vendor = tmp_path / "config.ini"
    vendor.write_text("vendor state must remain unchanged")
    with mock.patch.object(runner, "user_config_path", return_value=str(native)):
        with mock.patch.object(runner, "api_request") as request:
            with pytest.raises(RuntimeError, match="cannot overwrite"):
                runner.register(str(vendor))
    request.assert_not_called()
    assert vendor.read_text() == "vendor state must remain unchanged"


@pytest.mark.parametrize("kind", ["invalid", "symlink"])
def test_present_invalid_native_state_never_uses_legacy_credentials(tmp_path, kind):
    native = tmp_path / "native.ini"
    vendor = tmp_path / "config.ini"
    vendor.write_text("[device]\ntoken=TOK\nsecret=SEC\n")
    vendor.chmod(0o600)
    if kind == "symlink":
        native.symlink_to(vendor)
    else:
        native.write_text("[account]\nusername=incomplete\n")
        native.chmod(0o600)
    with mock.patch.object(runner, "user_config_path", return_value=str(native)):
        with mock.patch.object(runner, "legacy_config_path", return_value=str(vendor)):
            with pytest.raises(RuntimeError):
                runner.get_credentials()


def test_cli_requires_its_own_account_setup(tmp_path):
    vendor = tmp_path / "config.ini"
    vendor.write_text("[account]\nusername=user\n")
    vendor.chmod(0o600)
    with mock.patch.object(runner, "legacy_config_path", return_value=str(vendor)):
        assert not runner.cli_account_configured()
        vendor.write_text("[account]\nusername=user\npassword=secret\n")
        assert runner.cli_account_configured()
        vendor.chmod(0o644)
        assert not runner.cli_account_configured()

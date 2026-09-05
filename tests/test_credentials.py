"""Backend credentials regression tests."""

import configparser
import json
import os
import tempfile
from unittest import mock

from runner_support import load_runner

runner = load_runner()


def test_find_config_path_env_override():
    with tempfile.NamedTemporaryFile(suffix=".ini") as tf:
        old = os.environ.get("CYBERGHOST_CONFIG")
        os.environ["CYBERGHOST_CONFIG"] = tf.name
        try:
            assert runner.find_config_path() == tf.name
        finally:
            if old is None:
                del os.environ["CYBERGHOST_CONFIG"]
            else:
                os.environ["CYBERGHOST_CONFIG"] = old


def test_reject_symlink_config():
    d = tempfile.mkdtemp()
    target_real = os.path.join(d, "real_config.ini")
    symlink_path = os.path.join(d, "symlink_config.ini")
    with open(target_real, "w") as f:
        f.write("[device]\ntoken = T\nsecret = S\n")
    os.symlink(target_real, symlink_path)

    # get_credentials must raise RuntimeError if pointed to a symlink
    try:
        runner.get_credentials(symlink_path)
        raise AssertionError("Expected RuntimeError when loading config from symlink")
    except RuntimeError as e:
        assert "symlink" in str(e).lower()


def test_check_output_shape():
    import io
    from contextlib import redirect_stdout

    buf = io.StringIO()
    with mock.patch.object(runner, "system_binary_available", return_value=False):
        with mock.patch.object(runner.importlib.util, "find_spec", return_value=object()):
            with mock.patch.object(runner, "get_credentials", side_effect=RuntimeError("not configured")):
                with mock.patch.object(runner, "secure_helper_installed", return_value=False):
                    with mock.patch.object(runner, "installed_helper_version", return_value=""):
                        with mock.patch.object(runner, "secure_system_file", return_value=False):
                            with mock.patch.object(runner, "user_polkit_marker_installed", return_value=False):
                                with redirect_stdout(buf):
                                    runner.check()
    data = json.loads(buf.getvalue())
    expected_keys = {
        "wg_tools",
        "dns_tools",
        "requests",
        "cli",
        "cli_configured",
        "credentials",
        "helper_installed",
        "helper_version",
        "plugin_version",
        "polkit_rule_installed",
    }
    assert set(data) == expected_keys
    for key, value in data.items():
        if key in {"helper_version", "plugin_version"}:
            assert isinstance(value, str)
        else:
            assert isinstance(value, bool)


def test_register_payload_shapes():
    login = runner.build_login_payload("user@example.com", "pw")
    assert login == {"userName": "user@example.com", "password": "pw"}

    device = runner.build_device_payload("omarchy")
    assert device["data"]["linuxApp"] is True
    assert device["data"]["machineName"] == "omarchy"


def test_write_user_config():
    d = tempfile.mkdtemp()
    path = os.path.join(d, ".cyberghost", "config.ini")
    os.makedirs(os.path.dirname(path), exist_ok=True)

    runner.write_user_config(
        path,
        "user@example.com",
        "omarchy",
        {"name": "", "token": "TOK", "tokenSecret": "SEC"},
    )
    cfg = configparser.ConfigParser()
    cfg.read(path)
    assert cfg.get("account", "username") == "user@example.com"
    assert not cfg.has_option("account", "password")
    assert cfg.get("device", "name") == "omarchy"  # falls back to device_name
    assert cfg.get("device", "token") == "TOK"
    assert cfg.get("device", "secret") == "SEC"  # tokenSecret -> secret
    assert not (os.stat(path).st_mode & 0o077)  # owner-only permissions
    assert not (os.stat(os.path.dirname(path)).st_mode & 0o077)


def test_register_uses_api_response_and_never_persists_password():
    d = tempfile.mkdtemp()
    config_path = os.path.join(d, "native.ini")

    def response(status_code, body):
        item = mock.Mock(status_code=status_code)
        item._cyberghost_body = json.dumps(body).encode()
        return item

    with mock.patch.dict(os.environ, {"CG_USERNAME": "user@example.com", "CG_PASSWORD": "secret"}, clear=False):
        with mock.patch.object(runner, "user_config_path", return_value=config_path):
            with mock.patch.object(runner.socket, "gethostname", return_value="test-host"):
                with mock.patch.object(
                    runner,
                    "api_request",
                    side_effect=[
                        response(200, {"jwt": "jwt-token"}),
                        response(201, {"name": "test-host", "token": "TOK", "tokenSecret": "SEC"}),
                    ],
                ):
                    runner.register()

    cfg = configparser.ConfigParser()
    cfg.read(config_path)
    assert cfg.get("account", "username") == "user@example.com"
    assert not cfg.has_option("account", "password")
    assert cfg.get("device", "secret") == "SEC"
    # register() must scrub the env vars it consumed so they cannot leak
    # into a later subprocess or a captured traceback.
    assert "CG_USERNAME" not in os.environ
    assert "CG_PASSWORD" not in os.environ
    os.unlink(config_path)
    os.rmdir(d)


def test_register_scrubs_env_vars_even_when_api_fails():
    """register() must clear CG_USERNAME/CG_PASSWORD from os.environ even if the API call raises."""

    def response(status_code, body):
        item = mock.Mock(status_code=status_code)
        item._cyberghost_body = json.dumps(body).encode()
        return item

    env = {"CG_USERNAME": "user@example.com", "CG_PASSWORD": "secret"}
    with mock.patch.dict(os.environ, env, clear=False):
        with mock.patch.object(runner, "user_config_path", return_value="/tmp/cyberghost-scrub-test.ini"):
            with mock.patch.object(runner.socket, "gethostname", return_value="test-host"):
                with mock.patch.object(
                    runner,
                    "api_request",
                    side_effect=RuntimeError("network down"),
                ):
                    try:
                        runner.register()
                    except RuntimeError:
                        pass

    # The env vars must be gone whether register() succeeded or raised.
    assert "CG_USERNAME" not in os.environ
    assert "CG_PASSWORD" not in os.environ

"""Unit tests for cyberghost_runner.py.

Run with pytest (pytest -q) or directly (python3 tests/test_runner.py).
"""

import configparser
import importlib.util
import json
import os
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_runner():
    spec = importlib.util.spec_from_file_location("cyberghost_runner", ROOT / "cyberghost_runner.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


runner = load_runner()


def test_city_map_covers_countries_js():
    """Every country offered in the UI must have a native WireGuard city slug."""
    js = (ROOT / "Countries.js").read_text()
    codes = set(re.findall(r'"code":\s*"([A-Z]{2})"', js))
    mapped = set(runner.CITY_MAP)
    missing = codes - mapped
    assert not missing, f"Countries.js codes missing from CITY_MAP: {sorted(missing)}"


def test_build_wg_config_blocks_ipv6_leak():
    cfg = runner.build_wg_config("PRIV", "10.2.0.2", "SRVK", "1.2.3.4", 1337, dns_servers="1.1.1.1")
    assert "AllowedIPs = 0.0.0.0/0, ::/0" in cfg
    assert "PrivateKey = PRIV" in cfg
    assert "DNS = 1.1.1.1" in cfg
    assert cfg.endswith("PersistentKeepalive = 25\n")

    lean = runner.build_wg_config("P", "10.2.0.2", "K", "1.2.3.4", 1337)
    assert "DNS" not in lean


def test_parse_handshake_seconds():
    assert runner.parse_handshake_seconds("latest handshake: 2 minutes, 34 seconds ago") == 154
    assert runner.parse_handshake_seconds("5 seconds ago") == 5
    assert runner.parse_handshake_seconds("1 hour 30 minutes ago") == 5400
    assert runner.parse_handshake_seconds("2 days ago") == 172800
    assert runner.parse_handshake_seconds("never") is None
    assert runner.parse_handshake_seconds("") is None


def test_parse_wg_show():
    sample = (
        "interface: cyberghost\n"
        "  public key: abcdef=\n"
        "  endpoint: 1.2.3.4:1337\n"
        "  allowed ips: 0.0.0.0/0\n"
        "  transfer: 1.5 GiB received, 200 MiB sent\n"
        "  latest handshake: 1 minute, 12 seconds ago\n"
    )
    info = runner.parse_wg_show(sample)
    assert info["endpoint"] == "1.2.3.4:1337"
    assert info["handshake_sec"] == 72
    assert "received" in info["transfer"]
    assert "public key" not in info


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


def test_check_output_shape():
    import io
    from contextlib import redirect_stdout

    buf = io.StringIO()
    with redirect_stdout(buf):
        runner.check()
    data = json.loads(buf.getvalue())
    assert set(data) == {"wg_tools", "requests", "cli", "credentials"}
    for value in data.values():
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
        path, "user@example.com", "pw", "omarchy",
        {"name": "", "token": "TOK", "tokenSecret": "SEC"},
    )
    cfg = configparser.ConfigParser()
    cfg.read(path)
    assert cfg.get("account", "username") == "user@example.com"
    assert cfg.get("account", "password") == "pw"
    assert cfg.get("device", "name") == "omarchy"          # falls back to device_name
    assert cfg.get("device", "token") == "TOK"
    assert cfg.get("device", "secret") == "SEC"            # tokenSecret -> secret
    assert not (os.stat(path).st_mode & 0o077)             # owner-only permissions


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except AssertionError as exc:
                failed += 1
                print(f"FAIL {name}: {exc}")
    sys.exit(1 if failed else 0)

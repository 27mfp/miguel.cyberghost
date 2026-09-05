"""Common fixtures for backend tests; no network or privileged commands."""

import base64
import importlib.util
import json
import pathlib
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_runner():
    spec = importlib.util.spec_from_file_location("cyberghost_runner", ROOT / "cyberghost_runner.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Valid WireGuard test keys (32 bytes base64 encoded = 44 chars ending in =)
SAMPLE_PRIV = base64.b64encode(b"A" * 32).decode("ascii")
SAMPLE_PUB = base64.b64encode(b"B" * 32).decode("ascii")


def native_success_response(runner):
    response = mock.Mock(status_code=200)
    response._cyberghost_body = json.dumps(
        {
            "status": "OK",
            "server_key": SAMPLE_PUB,
            "server_ip": "198.51.100.20",
            "server_port": 1337,
            "peer_ip": "10.2.0.2",
            "dns_servers": ["1.1.1.1"],
        }
    ).encode()
    return response

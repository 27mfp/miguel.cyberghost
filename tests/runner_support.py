"""Common fixtures for backend tests; no network or privileged commands."""

import base64
import importlib.util
import json
import pathlib
import sys
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _drop_cached_backend():
    """Give each test module the isolation the old monolith had.

    Before the split every test module executed an independent copy of the
    runner, so module-level caches started empty. Reload the internal package
    for each ``load_runner()`` to preserve that guarantee; modules already held
    by an earlier test keep working because they hold direct references.
    """
    for name in [name for name in sys.modules if name == "cyberghost" or name.startswith("cyberghost.")]:
        del sys.modules[name]


def load_runner():
    # The package lives beside the entry point; make it importable when pytest
    # is started through the console script (which does not add the rootdir).
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    _drop_cached_backend()
    spec = importlib.util.spec_from_file_location("cyberghost_runner", ROOT / "cyberghost_runner.py")
    mod = importlib.util.module_from_spec(spec)
    # Register before execution: the facade installs itself on this object so
    # that patching ``runner.<name>`` still reaches the owning submodule.
    sys.modules["cyberghost_runner"] = mod
    try:
        spec.loader.exec_module(mod)
    except Exception:
        sys.modules.pop("cyberghost_runner", None)
        raise
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

#!/usr/bin/python3 -Es
"""
CyberGhost VPN WireGuard backend for Omarchy.

Negotiates WireGuard keys with CyberGhost and runs the tunnel as an in-memory
NetworkManager connection. It runs as the desktop user: NetworkManager and
Polkit authorize the network change, so no root helper is installed.

The implementation lives in the internal ``cyberghost`` package; this module
stays the stable CLI entry point and exposes the historical module surface
(functions, constants and stdlib modules) so ``Service.qml`` and the test suite
keep working unchanged.
"""

import sys

import cyberghost as _backend
from cyberghost._compat import install as _install_compat


def _current_module():
    """Return this module object, including when loaded by a bare spec loader.

    ``importlib.util.spec_from_file_location`` + ``exec_module`` (used by a few
    subprocess regression tests) does not register the module in
    ``sys.modules``. Modules are garbage-collected containers that own their
    ``__dict__``, so the referrer scan recovers the object in that case.
    """
    module = sys.modules.get(__name__)
    if module is not None:
        return module
    import gc
    import types

    namespace = globals()
    for candidate in gc.get_referrers(namespace):
        if isinstance(candidate, types.ModuleType) and candidate.__dict__ is namespace:
            return candidate
    return None


_facade = _current_module()
if _facade is not None:
    _install_compat(_facade, _backend._compat_submodules)
else:  # pragma: no cover - only reachable from an exotic embedder
    globals().update({name: getattr(_backend, name) for name in _backend.__all__})

# Explicit binding so readers and linters see the CLI entry point.
main = _backend.cli.main


if __name__ == "__main__":
    main()

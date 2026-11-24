"""CyberGhost VPN backend, split by responsibility.

The public surface is the historical ``cyberghost_runner`` module surface: the
package delegates reads and attribute patches to the submodules below, so
existing CLI, QML and test call sites keep working unchanged. Import order
matters only in that it must be acyclic; ``credentials.logout`` imports the
NetworkManager lifecycle lazily.
"""

import sys

from . import (
    cli,
    constants,
    credentials,
    networkmanager,
    server_data,
    server_selection,
    setup,
    system,
    transport,
    validation,
    vendor,
    wireguard,
)
from ._compat import LIVE_STATE_NAMES, install

_compat_submodules = (
    constants,
    system,
    validation,
    transport,
    wireguard,
    credentials,
    vendor,
    server_data,
    server_selection,
    networkmanager,
    setup,
    cli,
)

__all__ = sorted(
    {
        name
        for module in _compat_submodules
        for name in vars(module)
        # Module dunders (__name__, __file__, ...) stay module-local.
        if not (name.startswith("__") and name.endswith("__"))
    }
    | set(LIVE_STATE_NAMES)
)

install(sys.modules[__name__], _compat_submodules)

"""Compatibility facade for the historical single-module runner.

Tests (and any external caller) import the backend through
``cyberghost_runner`` and patch attributes on that module object, for example
``monkeypatch.setattr(runner, "nm_active_state", fake)``. After the split the
real function lives in a submodule, so a plain re-export would let a patch on
the facade be silently ignored by the submodule that calls the function.

``CompatModule`` keeps that contract:

* every exported name is copied onto the facade, so ``mock.patch.object``
  recognises it as a real module attribute and can restore it;
* assigning a name owned by a submodule writes it into every submodule that
  already holds that global. That is exactly the set of call sites which would
  have observed the patch in the old monolith;
* a few module-level values are *rebound* at runtime instead of mutated in
  place (the pinned-TLS probe caches). Those are never copied: reads always
  resolve through ``__getattr__`` to the owning submodule, so a facade read
  cannot return an import-time snapshot.

The behaviour is covered by ``tests/test_module_facade.py``.
"""

import types

_SKIP_PREFIX = "__"

# Rebound (not mutated) module state: never snapshot these on a facade.
LIVE_STATE_NAMES = frozenset(
    {
        "_MAPPED_ADAPTER_CLASSES",
        "_MAPPED_HTTPS_PROBE_ERROR",
        "_MAPPED_HTTPS_PROBE_OK",
    }
)


class CompatModule(types.ModuleType):
    """A module that reads and writes through to its owning submodules."""

    def __getattr__(self, name):
        for module in self.__dict__.get("_compat_submodules", ()):
            if name in module.__dict__:
                return module.__dict__[name]
        raise AttributeError(f"module {self.__name__!r} has no attribute {name!r}")

    def __setattr__(self, name, value):
        if name.startswith(_SKIP_PREFIX) and name.endswith(_SKIP_PREFIX):
            super().__setattr__(name, value)
            return
        owners = [module for module in self.__dict__.get("_compat_submodules", ()) if name in module.__dict__]
        for module in owners:
            setattr(module, name, value)
        if owners and name not in self.__dict__:
            # Live state was never copied: keep resolving it through the owner
            # so reads observe later in-place rebinding.
            return
        super().__setattr__(name, value)


def install(module, submodules, live_state=LIVE_STATE_NAMES):
    """Copy the submodule surface onto *module* and enable patch forwarding."""
    namespace = module.__dict__
    for submodule in submodules:
        for name, value in vars(submodule).items():
            if name.startswith(_SKIP_PREFIX) and name.endswith(_SKIP_PREFIX):
                continue
            if name in live_state:
                continue
            namespace[name] = value
    namespace["_compat_submodules"] = tuple(submodules)
    module.__class__ = CompatModule

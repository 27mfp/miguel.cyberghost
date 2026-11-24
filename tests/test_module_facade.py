"""The split backend must keep the historical single-module patch contract.

These tests use the same ``load_runner()`` fixture as the rest of the suite:
they assert that the compatibility facade is a real behaviour boundary, not a
best-effort re-export.
"""

import importlib

import pytest
from runner_support import load_runner

runner = load_runner()
# Import after load_runner(): each test module gets a freshly loaded backend,
# so bind the names only once that instance exists.
backend = importlib.import_module("cyberghost")
transport_module = importlib.import_module("cyberghost.transport")


def test_facade_exposes_functions_constants_and_stdlib_modules():
    assert runner.PLUGIN_VERSION == "1.7.2"
    assert runner.INTERFACE == "cyberghost"
    assert runner.connect is backend.networkmanager.connect
    assert runner.os is backend.server_data.os
    assert runner.time is backend.server_data.time
    assert runner.importlib.util is not None
    assert callable(runner.main)


def test_patching_the_facade_reaches_the_calling_submodule(monkeypatch):
    calls = []

    def fake_inventory(country_code, server_type="traffic"):
        calls.append((country_code, server_type))
        return []

    monkeypatch.setattr(runner, "get_servers_for_country", fake_inventory)
    monkeypatch.setattr(runner, "known_servers", lambda country: [])

    with pytest.raises(RuntimeError, match="no WireGuard servers"):
        runner.select_native_candidates("PT")

    assert calls == [("PT", "traffic")]
    # The owning submodule is what actually calls the helper.
    assert backend.server_selection.get_servers_for_country is fake_inventory


def test_patching_the_facade_restores_every_copy(monkeypatch):
    original = runner.load_account
    monkeypatch.setattr(runner, "load_account", lambda path=None: {"jwt": ""})
    assert backend.networkmanager.load_account is not original

    monkeypatch.undo()
    assert runner.load_account is original
    assert backend.networkmanager.load_account is original
    assert backend.server_data.load_account is original


def test_rebound_module_state_is_read_live():
    """A cached facade snapshot would hide the probe result set at runtime."""
    transport_module._MAPPED_HTTPS_PROBE_OK = None
    try:
        assert runner._MAPPED_HTTPS_PROBE_OK is None
        transport_module._MAPPED_HTTPS_PROBE_OK = True
        assert runner._MAPPED_HTTPS_PROBE_OK is True
    finally:
        transport_module._MAPPED_HTTPS_PROBE_OK = None


def test_unknown_attribute_raises_attribute_error():
    with pytest.raises(AttributeError):
        runner.definitely_not_a_runner_symbol  # noqa: B018 - attribute access is the assertion

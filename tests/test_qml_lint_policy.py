"""The native lint gate must not turn project mistakes into host exceptions."""

import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("qml_checker", Path(__file__).parents[1] / "scripts/check_qml.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def test_known_dynamic_host_metadata_is_narrowly_identified():
    assert checker.host_metadata_gap(
        {"id": "missing-property", "message": 'Member "caption" not found on type "QObject"'}
    )
    assert not checker.host_metadata_gap(
        {"id": "missing-property", "message": 'Member "caption" not found on type "SetupCard"'}
    )
    assert not checker.host_metadata_gap(
        {"id": "missing-property", "message": 'Member "captino" not found on type "QObject"'}
    )
    assert not checker.host_metadata_gap({"id": "import", "message": "Failed to import qs.Ui"})
    assert not checker.host_metadata_gap({"id": "signal-handler-parameters", "message": "Unknown signal"})

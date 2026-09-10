#!/usr/bin/env python3
"""Validate the plugin manifest without requiring a full Omarchy checkout."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "manifest.json"


def fail(message: str) -> None:
    raise SystemExit(f"manifest validation failed: {message}")


def main() -> int:
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(str(exc))

    if not isinstance(manifest, dict):
        fail("root must be an object")
    if manifest.get("schemaVersion") != 1:
        fail("schemaVersion must be 1")
    if manifest.get("id") != "miguel.cyberghost":
        fail("id must be miguel.cyberghost")
    if manifest.get("kinds") != ["bar-widget"]:
        fail("native release must declare only the bar-widget kind")

    entrypoints = manifest.get("entryPoints")
    if not isinstance(entrypoints, dict) or entrypoints.get("barWidget") != "BarWidget.qml":
        fail("entryPoints.barWidget must be BarWidget.qml")
    if not (ROOT / "BarWidget.qml").is_file():
        fail("BarWidget.qml is missing")

    bar = manifest.get("barWidget")
    if not isinstance(bar, dict):
        fail("barWidget must be an object")
    if bar.get("allowMultiple") is not False:
        fail("barWidget.allowMultiple must be false")
    if bar.get("defaultSection") not in {"left", "center", "right"}:
        fail("barWidget.defaultSection is invalid")
    defaults = bar.get("defaults")
    schema = bar.get("schema")
    if not isinstance(defaults, dict) or not isinstance(schema, list):
        fail("barWidget defaults and schema are required")

    keys: set[str] = set()
    for item in schema:
        if not isinstance(item, dict) or not isinstance(item.get("key"), str):
            fail("each schema item needs a string key")
        key = item["key"]
        if key in keys:
            fail(f"duplicate schema key: {key}")
        keys.add(key)
        if "defaultValue" not in item:
            fail(f"schema item lacks defaultValue: {key}")
        if key not in defaults:
            fail(f"schema key lacks a matching default: {key}")

    if keys != set(defaults):
        fail("defaults and schema keys differ")
    print(f"manifest valid: {MANIFEST_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

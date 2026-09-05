#!/usr/bin/env bash
# Qt unit/component tests, not another Quickshell process.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
QT_BIN="${QT_BIN:-/usr/lib/qt6/bin}"
"$QT_BIN/qmltestrunner" -input "$ROOT/tests/qml" -platform offscreen
# The shell's Quickshell types are statically registered in its executable,
# unavailable to standalone qmltestrunner. Use explicit host-boundary doubles.
"$QT_BIN/qmltestrunner" -import "$ROOT/tests/support/imports" -input "$ROOT/tests/ui" -platform offscreen

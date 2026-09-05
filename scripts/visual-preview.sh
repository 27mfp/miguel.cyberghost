#!/usr/bin/env bash
# Explicit, synthetic-data preview in the existing Omarchy shell.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ID="test.cyberghost-visual"
TARGET="$HOME/.config/omarchy/plugins/$ID"
case "${1:---help}" in
  --install)
    [[ ! -e "$TARGET" && ! -L "$TARGET" ]] || { echo "Preview already exists; remove it first." >&2; exit 1; }
    STAGE=$(mktemp -d)
    trap 'rm -rf -- "$STAGE"' EXIT
    cp "$ROOT"/*.qml "$ROOT"/*.js "$STAGE/"
    cp "$ROOT/tests/visual/Fixture.qml" "$STAGE/"
    cp "$ROOT/tests/visual/manifest.json" "$STAGE/manifest.json"
    omarchy plugin validate "$STAGE"
    mv "$STAGE" "$TARGET"
    omarchy-shell shell rescanPlugins
    echo "Preview installed. Enable and summon after discovery:"
    echo "omarchy plugin enable $ID"
    echo "omarchy-shell shell summon $ID '{}'"
    ;;
  --remove)
    omarchy plugin remove "$ID" --yes
    ;;
  *)
    echo "Usage: bash scripts/visual-preview.sh --install|--remove"
    echo "Uses real shell components with synthetic service data. Never connects a VPN."
    ;;
esac

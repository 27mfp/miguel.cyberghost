#!/usr/bin/env bash
# Install the fixed root helper and optional Polkit rule from a visible terminal.
#
# This script deliberately uses sudo in the user's terminal. The Omarchy panel
# must not pass a user-editable plugin path to pkexec's root install operation.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="/usr/local/bin/cyberghost-runner"
RULE_PATH="/etc/polkit-1/rules.d/50-cyberghost.rules"
MARKER_DIR="$HOME/.local/state/cyberghost"
MARKER_PATH="$MARKER_DIR/polkit-rule-installed"

[[ -f "$DIR/cyberghost_runner.py" ]] || { echo "Missing cyberghost_runner.py" >&2; exit 1; }
[[ -f "$DIR/50-cyberghost.rules" ]] || { echo "Missing 50-cyberghost.rules" >&2; exit 1; }

echo "Installing root helper and Polkit rule..."
sudo install -o root -g root -m 0755 "$DIR/cyberghost_runner.py" "$HELPER_PATH"
sudo install -D -o root -g root -m 0644 "$DIR/50-cyberghost.rules" "$RULE_PATH"

mkdir -p "$MARKER_DIR"
chmod 700 "$MARKER_DIR"
printf '%s\n' 'cyberghost-polkit-rule-v1' > "$MARKER_PATH"
chmod 600 "$MARKER_PATH"

echo "Helper installed: $HELPER_PATH"
echo "Polkit rule installed: $RULE_PATH"
echo "Run 'Recheck setup' in the widget when you return to Omarchy."

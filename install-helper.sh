#!/usr/bin/env bash
# Install the fixed root helper and optional Polkit rule from a visible terminal.
#
# This script deliberately uses sudo in the user's terminal. The Omarchy panel
# must not pass a user-editable plugin path to pkexec's root install operation.
# By default it installs the helper and optional Polkit rule; pass
# --no-polkit-rule (or --helper-only) to install only the helper.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="/usr/local/bin/cyberghost-runner"
RULE_PATH="/etc/polkit-1/rules.d/50-cyberghost.rules"
MARKER_DIR="$HOME/.local/state/cyberghost"
MARKER_PATH="$MARKER_DIR/polkit-rule-installed"
INSTALL_POLKIT=1
SNAPSHOT_DIR=""
ROOT_STAGE_DIR=""

cleanup() {
  # The root staging directory is inaccessible to the invoking user. Use -n so
  # cleanup never opens a second password prompt after an interrupted install.
  if [[ -n "${ROOT_STAGE_DIR:-}" ]]; then
    /usr/bin/sudo -n /usr/bin/rm -rf -- "$ROOT_STAGE_DIR" 2>/dev/null || true
  fi
  if [[ -n "${SNAPSHOT_DIR:-}" ]]; then
    /usr/bin/rm -rf -- "$SNAPSHOT_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --no-polkit-rule | --helper-only) INSTALL_POLKIT=0 ;;
    -h | --help)
      printf 'Usage: %s [--no-polkit-rule|--helper-only]\n' "$(basename "$0")"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

require_regular_source() {
  local source="$1"
  if [[ ! -f "$source" || -L "$source" ]]; then
    echo "Missing or non-regular installer source: $source" >&2
    exit 1
  fi
}

snapshot_source() {
  local source="$1"
  local snapshot="$2"
  require_regular_source "$source"
  # Read each checkout file exactly once, before sudo can prompt. Later root
  # operations use only this private snapshot, never the mutable checkout.
  /usr/bin/cp -- "$source" "$snapshot"
  /usr/bin/chmod 0400 "$snapshot"
}

sha256_file() {
  local digest
  digest=$(/usr/bin/sha256sum -- "$1")
  digest="${digest%% *}"
  if [[ ! "$digest" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "Could not calculate a valid SHA-256 digest for $1" >&2
    exit 1
  fi
  printf '%s' "$digest"
}

copy_to_root_stage() {
  local snapshot="$1"
  local name="$2"
  # The destination is root-owned and mode 0600, so a user cannot change the
  # bytes after this copy while the privileged verification is running.
  /usr/bin/sudo /usr/bin/install -o root -g root -m 0600 -- "$snapshot" "$ROOT_STAGE_DIR/$name"
}

verify_root_stage() {
  local name="$1"
  local expected="$2"
  local actual
  actual=$(/usr/bin/sudo /usr/bin/sha256sum -- "$ROOT_STAGE_DIR/$name")
  actual="${actual%% *}"
  if [[ "$actual" != "$expected" ]]; then
    echo "Refusing installation: $name changed while authorization was pending." >&2
    exit 1
  fi
}

# Create a private, read-only snapshot and bind it to digests before the first
# privileged command. If a checkout file changes while sudo is authenticating,
# the root-owned copy below will fail verification and nothing is installed.
SNAPSHOT_DIR=$(/usr/bin/mktemp -d /tmp/cyberghost-install.XXXXXX)
snapshot_source "$DIR/cyberghost_runner.py" "$SNAPSHOT_DIR/cyberghost_runner.py"
HELPER_DIGEST=$(sha256_file "$SNAPSHOT_DIR/cyberghost_runner.py")

RULE_DIGEST=""
if (( INSTALL_POLKIT )); then
  snapshot_source "$DIR/50-cyberghost.rules" "$SNAPSHOT_DIR/50-cyberghost.rules"
  RULE_DIGEST=$(sha256_file "$SNAPSHOT_DIR/50-cyberghost.rules")
fi

# Prompt only after both input files have been snapshotted. The root staging
# directory is inaccessible to the invoking user and is removed on exit.
#
# We use a PID-based path instead of `sudo mktemp` in a subshell because the
# fingerprint-reader auth prompt is sent to stdout (not /dev/tty) when sudo
# runs without a controlling terminal — and `$(sudo …)` captures stdout into
# the variable, corrupting the path. mkdir without -p is load-bearing: if an
# attacker pre-creates this path, the install must abort rather than write
# root-owned files into a user-owned directory.
ROOT_STAGE_DIR="/tmp/cyberghost-install-root-$$"
if [[ -e "$ROOT_STAGE_DIR" ]]; then
  echo "Refusing to reuse an existing staging path: $ROOT_STAGE_DIR" >&2
  exit 1
fi
/usr/bin/sudo /usr/bin/mkdir -m 0700 -- "$ROOT_STAGE_DIR" || {
  echo "Could not create the root staging directory at $ROOT_STAGE_DIR." >&2
  exit 1
}
copy_to_root_stage "$SNAPSHOT_DIR/cyberghost_runner.py" cyberghost_runner.py
if (( INSTALL_POLKIT )); then
  copy_to_root_stage "$SNAPSHOT_DIR/50-cyberghost.rules" 50-cyberghost.rules
fi

# Verify all root-owned staging files before installing either final file.
verify_root_stage cyberghost_runner.py "$HELPER_DIGEST"
if (( INSTALL_POLKIT )); then
  verify_root_stage 50-cyberghost.rules "$RULE_DIGEST"
fi

echo "Installing verified root helper..."
/usr/bin/sudo /usr/bin/install -o root -g root -m 0755 -- "$ROOT_STAGE_DIR/cyberghost_runner.py" "$HELPER_PATH"

if (( INSTALL_POLKIT )); then
  echo "Installing verified optional Polkit rule..."
  /usr/bin/sudo /usr/bin/install -D -o root -g root -m 0644 -- "$ROOT_STAGE_DIR/50-cyberghost.rules" "$RULE_PATH"
  mkdir -p "$MARKER_DIR"
  chmod 700 "$MARKER_DIR"
  printf '%s\n' 'cyberghost-polkit-rule-v1' > "$MARKER_PATH"
  chmod 600 "$MARKER_PATH"
  echo "Polkit rule installed: $RULE_PATH"
else
  /usr/bin/sudo /usr/bin/rm -f -- "$RULE_PATH"
  rm -f -- "$MARKER_PATH"
  echo "Skipped optional Polkit rule; pkexec will ask for authorization."
fi

echo "Helper installed: $HELPER_PATH"
echo "Close this terminal to return to Omarchy; the widget rechecks setup automatically."

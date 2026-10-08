#!/usr/bin/env bash
# Remove the root helper and optional Polkit rule installed by releases before
# 1.7. Connections now run through NetworkManager as the desktop user, so these
# files no longer grant anything the plugin needs.
#
# Opened by the widget in Omarchy's floating terminal, or run by hand:
#   bash scripts/remove-legacy-helper.sh
set -euo pipefail

ASSUME_YES=0
STRICT=0
while (($#)); do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --strict) STRICT=1 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

HELPER_PATH="/usr/local/bin/cyberghost-runner"
RULE_PATH="/etc/polkit-1/rules.d/50-cyberghost.rules"
WG_CONF_PATH="/etc/wireguard/cyberghost.conf"
LOCK_PATH="/run/lock/cyberghost.lock"
MARKER_PATH="$HOME/.local/state/cyberghost/polkit-rule-installed"

[[ $EUID != 0 ]] || { echo "Run as your desktop user; this script invokes sudo." >&2; exit 1; }

RUNNER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/cyberghost_runner.py"

# A tunnel the old helper created can only be removed by that helper. Keep it
# installed until the widget has disconnected that tunnel. NetworkManager also
# lists such an externally created interface as an active "cyberghost"
# connection, so ask the runner: it tells ours apart by its profile UUID.
if ! backend=$(/usr/bin/python3 "$RUNNER" status --json \
  | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin).get("backend") or "")'); then
  echo "Could not verify the VPN state; nothing was removed." >&2
  exit 1
fi
if [[ "$backend" == "legacy" ]]; then
  echo "A tunnel from the old helper is still active. Disconnect it from the widget first." >&2
  exit 1
fi

echo "This removes the files installed by earlier CyberGhost plugin releases:"
echo "  $HELPER_PATH"
echo "  $RULE_PATH (only the plugin's own rule; a customized file is left alone)"
echo "  $LOCK_PATH is preserved to avoid replacing a held advisory lock."
echo "  $WG_CONF_PATH is preserved: its contents do not prove plugin ownership."
if (( ! ASSUME_YES )); then
  read -rp "Continue? [y/N] " answer || answer=""
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Nothing was changed."; exit 0; }
fi

/usr/bin/sudo /usr/bin/bash -s -- "$HELPER_PATH" "$RULE_PATH" "$WG_CONF_PATH" "$LOCK_PATH" "$STRICT" <<'ROOT'
set -euo pipefail
helper="$1" rule="$2" wg_conf="$3" lock="$4" strict="$5"

trusted_root_file() {
  [[ -f "$1" && ! -L "$1" && "$(/usr/bin/stat -c '%u' -- "$1")" == 0 ]]
}

recognized_helper() {
  trusted_root_file "$helper" && /usr/bin/grep -q '^PLUGIN_VERSION = "' -- "$helper" \
    && /usr/bin/grep -q 'cyberghost' -- "$helper"
}

recognized_rule() {
  local programs
  programs=$(/usr/bin/grep -o 'lookup("program") === "[^"]*"' -- "$rule" | /usr/bin/sort -u || true)
  trusted_root_file "$rule" && { [[ "$programs" == "lookup(\"program\") === \"$helper\"" ]] \
    || /usr/bin/grep -q 'cyberghost_runner\.py' -- "$rule"; }
}

# Preflight before deleting anything. Developer reset must preserve the current
# plugin if authorization fails or a system file has an unknown owner/purpose.
if (( strict )); then
  for path in "$helper" "$rule"; do
    if [[ -e "$path" || -L "$path" ]]; then
      if [[ "$path" == "$helper" ]]; then
        recognized_helper || { echo "Unrecognized helper; reset aborted." >&2; exit 1; }
      else
        recognized_rule || { echo "Customized rule; reset aborted." >&2; exit 1; }
      fi
    fi
  done
fi
# Recheck after authorization, not only before the confirmation/password prompt.
if /usr/bin/ip link show cyberghost >/dev/null 2>&1; then
  echo "A cyberghost interface is present; disconnect before cleanup." >&2
  exit 1
fi

if [[ -e "$helper" ]]; then
  if recognized_helper; then
    /usr/bin/rm -f -- "$helper"
    echo "Removed $helper"
  else
    echo "Left $helper in place: it is not the plugin's helper." >&2
  fi
fi

if [[ -e "$rule" ]]; then
  if recognized_rule; then
    /usr/bin/rm -f -- "$rule"
    echo "Removed $rule"
  else
    echo "Left $rule in place: it has been customized. Inspect it manually." >&2
  fi
fi

# No unique ownership marker exists in historical WireGuard configs. Preserve
# them rather than deleting a possibly customized or repurposed configuration.
if [[ -e "$wg_conf" ]]; then
  echo "Preserved $wg_conf; remove manually if no longer needed."
fi
# Advisory lock paths must persist: unlinking a held inode lets another
# process lock a replacement inode and bypass lifecycle serialization.
if [[ -e "$lock" ]]; then
  echo "Preserved $lock (advisory lock)."
fi
ROOT

rm -f -- "$MARKER_PATH"
echo "Done. The widget rechecks setup when this terminal closes."

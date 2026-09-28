#!/usr/bin/env bash
# Remove the root helper and optional Polkit rule installed by releases before
# 1.7. Connections now run through NetworkManager as the desktop user, so these
# files no longer grant anything the plugin needs.
#
# Opened by the widget in Omarchy's floating terminal, or run by hand:
#   bash scripts/remove-legacy-helper.sh
set -euo pipefail

HELPER_PATH="/usr/local/bin/cyberghost-runner"
RULE_PATH="/etc/polkit-1/rules.d/50-cyberghost.rules"
WG_CONF_PATH="/etc/wireguard/cyberghost.conf"
LOCK_PATH="/run/lock/cyberghost.lock"
MARKER_PATH="$HOME/.local/state/cyberghost/polkit-rule-installed"

[[ $EUID != 0 ]] || { echo "Run as your desktop user; this script invokes sudo." >&2; exit 1; }

# A tunnel the old helper created can only be removed by that helper. Keep it
# installed until the widget has disconnected that tunnel.
if /usr/bin/ip link show cyberghost >/dev/null 2>&1 \
  && ! /usr/bin/nmcli -t -f DEVICE connection show --active 2>/dev/null | /usr/bin/grep -qx cyberghost; then
  echo "A tunnel from the old helper is still active. Disconnect it from the widget first." >&2
  exit 1
fi

echo "This removes the files installed by earlier CyberGhost plugin releases:"
echo "  $HELPER_PATH"
echo "  $RULE_PATH (only the plugin's own rule; a customized file is left alone)"
echo "  $WG_CONF_PATH and $LOCK_PATH"
read -rp "Continue? [y/N] " answer || answer=""
[[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Nothing was changed."; exit 0; }

/usr/bin/sudo /usr/bin/bash -s -- "$HELPER_PATH" "$RULE_PATH" "$WG_CONF_PATH" "$LOCK_PATH" <<'ROOT'
set -euo pipefail
helper="$1" rule="$2" wg_conf="$3" lock="$4"

trusted_root_file() {
  [[ -f "$1" && ! -L "$1" && "$(/usr/bin/stat -c '%u' -- "$1")" == 0 ]]
}

if [[ -e "$helper" ]]; then
  # Only delete the plugin's own helper, recognized by its version marker.
  if trusted_root_file "$helper" && /usr/bin/grep -q '^PLUGIN_VERSION = "' -- "$helper" \
    && /usr/bin/grep -q 'cyberghost' -- "$helper"; then
    /usr/bin/rm -f -- "$helper"
    echo "Removed $helper"
  else
    echo "Left $helper in place: it is not the plugin's helper." >&2
  fi
fi

if [[ -e "$rule" ]]; then
  programs=$(/usr/bin/grep -o 'lookup("program") === "[^"]*"' -- "$rule" | /usr/bin/sort -u || true)
  # Releases before 1.5 matched python3 running the user-writable plugin
  # runner. Such a rule is a standing root grant and is always removed.
  if trusted_root_file "$rule" && { [[ "$programs" == "lookup(\"program\") === \"$helper\"" ]] \
    || /usr/bin/grep -q 'cyberghost_runner\.py' -- "$rule"; }; then
    /usr/bin/rm -f -- "$rule"
    echo "Removed $rule"
  else
    echo "Left $rule in place: it has been customized. Inspect it manually." >&2
  fi
fi

if ! /usr/bin/ip link show cyberghost >/dev/null 2>&1; then
  if trusted_root_file "$wg_conf"; then
    /usr/bin/rm -f -- "$wg_conf"
    echo "Removed $wg_conf"
  fi
fi
if trusted_root_file "$lock"; then
  /usr/bin/rm -f -- "$lock"
fi
ROOT

rm -f -- "$MARKER_PATH"
echo "Done. The widget rechecks setup when this terminal closes."

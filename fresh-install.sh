#!/usr/bin/env bash
# CyberGhost plugin — simulate a brand-new user.
#
# Removes plugin-owned state (widget, helper/rule, native credentials), but
# preserves the vendor CLI config, which may still satisfy legacy readiness.
# Reinstalls from a staged and validated source. Configuration (dependencies,
# account link, root-helper installation and optional passwordless rule) is
# completed through the widget's FIRST-RUN SETUP panel.
#
# Usage:
#   bash fresh-install.sh [--local] [--purge-deps] [-y]
#
#   --local       install THIS checkout into the plugins dir instead of
#                 cloning from GitHub (tests uncommitted edits without a push)
#   --purge-deps  also uninstall wireguard-tools and python-requests
#   -y            no confirmation prompts
#   -h, --help    print this usage text

set -euo pipefail

PLUGIN_ID="miguel.cyberghost"
PLUGIN_URL="https://github.com/27mfp/miguel.cyberghost.git"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
POLKIT_RULE="/etc/polkit-1/rules.d/50-cyberghost.rules"
POLKIT_MARKER="$HOME/.local/state/cyberghost/polkit-rule-installed"

GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
step() { printf "\n${BOLD}==> %s${NC}\n" "$1"; }
ok() { printf "${GREEN}✓${NC} %s\n" "$1"; }

ASSUME_YES=0 FROM_LOCAL=0 PURGE_DEPS=0
STAGE_ROOT=""
SOURCE_DIR=""

cleanup() {
  if [[ -n "${STAGE_ROOT:-}" && -d "$STAGE_ROOT" ]]; then
    rm -rf -- "$STAGE_ROOT"
  fi
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --local) FROM_LOCAL=1 ;;
    --github) echo "--github is now the default; use --local for the local checkout" >&2 ;;
    --purge-deps) PURGE_DEPS=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    -h | --help)
      sed -n '5,18p' "$0"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ -x /usr/bin/jq ]] || {
  echo "fresh-install.sh requires jq; install it before starting (for example: sudo pacman -S jq)." >&2
  exit 1
}

confirm() {
  (( ASSUME_YES )) && return 0
  local answer=""
  # Reset is destructive: EOF, blank input and arbitrary text all refuse it.
  read -rp "$1 [y/N] " answer || return 1
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

confirm "Reset everything and simulate a fresh CyberGhost plugin install?" || {
  echo "Aborted."
  exit 0
}

# Stage and validate the replacement before any installed files are removed.
# This also makes --local safe when the script itself is executed from the
# installed plugin directory.
step "Staging replacement plugin"
STAGE_ROOT=$(/usr/bin/mktemp -d /tmp/cyberghost-fresh.XXXXXX)
SOURCE_DIR="$STAGE_ROOT/$PLUGIN_ID"
mkdir -p "$SOURCE_DIR"
if (( FROM_LOCAL )); then
  cp -a "$REPO_DIR"/. "$SOURCE_DIR"/
else
  GIT_TERMINAL_PROMPT=0 /usr/bin/git clone --depth 1 -- "$PLUGIN_URL" "$SOURCE_DIR"
fi
/usr/bin/jq -e --arg id "$PLUGIN_ID" '.id == $id and .entryPoints.barWidget == "BarWidget.qml"' \
  "$SOURCE_DIR/manifest.json" >/dev/null
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate "$SOURCE_DIR"
fi
rm -rf "$SOURCE_DIR/__pycache__"
ok "replacement staged and manifest validated"

# ---------------------------------------------------------------------------
step "Disconnecting any live VPN tunnel"
qs ipc call "$PLUGIN_ID" disconnect >/dev/null 2>&1 || true
connected=""
for _ in $(seq 1 30); do
  status_json=$(/usr/bin/python3 "$REPO_DIR/cyberghost_runner.py" status --json 2>/dev/null) || {
    echo "WARNING: status verification failed — disconnect manually before continuing." >&2
    exit 1
  }
  connected=$(printf '%s' "$status_json" | /usr/bin/jq -er \
    'if (.connected | type) == "boolean" then (.connected | tostring) else error("missing boolean connected state") end') || {
    echo "WARNING: status verification returned malformed JSON — aborting." >&2
    exit 1
  }
  [[ $connected == "false" ]] && break
  sleep 0.5
done
if [[ $connected != "false" ]]; then
  echo "WARNING: could not verify that the tunnel is down — disconnect manually before continuing." >&2
  exit 1
fi
ok "tunnel down"

# ---------------------------------------------------------------------------
step "Removing plugin from Omarchy"
omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null 2>&1 || true
# Remove only the fixed plugin target. Do not sweep unrelated Omarchy backups.
rm -rf -- "${PLUGINS_DIR:?}/$PLUGIN_ID"
ok "widget removed from bar and plugins dir"

# ---------------------------------------------------------------------------
step "Removing Polkit rule and root helper"
if /usr/bin/sudo /usr/bin/rm -f -- "$POLKIT_RULE" /usr/local/bin/cyberghost-runner; then
  rm -f -- "$POLKIT_MARKER"
  ok "polkit rule and root helper removed"
else
  echo "Could not remove the root helper or Polkit rule; reset aborted." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
step "Removing native plugin credentials (preserving the vendor CLI)"
rm -f -- "$HOME/.cyberghost/native.ini"
ok "Native credentials removed. Legacy config.ini is preserved and may still provide account access."

# ---------------------------------------------------------------------------
if (( PURGE_DEPS )); then
  step "Uninstalling dependencies (bare-machine simulation)"
  if /usr/bin/sudo /usr/bin/pacman -Rns --noconfirm wireguard-tools python-requests >/dev/null 2>&1; then
    ok "wireguard-tools + python-requests removed"
  else
    echo "- still needed by other packages; wizard will show them installed"
  fi
fi

# ---------------------------------------------------------------------------
step "Installing staged plugin into plugins directory"
mkdir -p "$PLUGINS_DIR"
rm -rf -- "${PLUGINS_DIR:?}/$PLUGIN_ID"
mv -- "$SOURCE_DIR" "${PLUGINS_DIR:?}/$PLUGIN_ID"
SOURCE_DIR=""
omarchy shell rescanPlugins >/dev/null 2>&1 || true
section=$(/usr/bin/jq -r '.barWidget.defaultSection // "right"' "$PLUGINS_DIR/$PLUGIN_ID/manifest.json")
omarchy plugin enable "$PLUGIN_ID" "$section"

# ---------------------------------------------------------------------------
step "Restarting shell"
omarchy restart shell

printf '\n%s\n' "${GREEN}Fresh state restored.${NC}"
cat <<DONE

Now finish as a brand-new user through the WIDGET:

  1. Click the ghost icon in the bar (${section} section).
  2. The FIRST-RUN SETUP panel appears. Use its buttons:
       - Install        -> wireguard-tools + python-requests (pkexec prompt)
       - Link account   -> your CyberGhost username/password
       - Install helper -> visible terminal with the fixed root helper and optional Polkit rule (sudo)
       - Recheck        -> optional; the panel rechecks automatically when the installer terminal closes
  3. Once the required dependency, account and helper items are green, the full panel unlocks; Polkit remains optional:
     connect, pick countries, server modes, protocols.

DONE

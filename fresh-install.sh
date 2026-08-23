#!/usr/bin/env bash
# CyberGhost plugin — simulate a brand-new user.
#
# Wipes every trace of the plugin (widget, polkit rule, account credentials)
# and reinstalls it from the public GitHub URL exactly like a first-time
# external user — then it's hands off: ALL configuration (dependencies,
# account link, optional passwordless rule) is meant to be done through the
# widget's FIRST-RUN SETUP panel, never via install.sh or the terminal.
#
# Usage:
#   bash fresh-install.sh [--local] [--purge-deps] [-y]
#
#   --local       install THIS checkout into the plugins dir instead of
#                 cloning from GitHub (tests uncommitted edits without a push)
#   --purge-deps  also uninstall wireguard-tools and python-requests so the
#                 wizard's one-click Install starts from a truly bare machine.
#   -y            no confirmation prompts.

set -euo pipefail

PLUGIN_ID="miguel.cyberghost"
PLUGIN_URL="https://github.com/27mfp/miguel.cyberghost.git"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
POLKIT_RULE="/etc/polkit-1/rules.d/50-cyberghost.rules"

GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
step() { printf "\n${BOLD}==> %s${NC}\n" "$1"; }
ok() { printf "${GREEN}✓${NC} %s\n" "$1"; }

ASSUME_YES=0 FROM_LOCAL=0 PURGE_DEPS=0
while (($#)); do
  case "$1" in
    --local) FROM_LOCAL=1 ;;
    --github) echo "--github is now the default; use --local for the local checkout" >&2 ;;
    --purge-deps) PURGE_DEPS=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

confirm() {
  (( ASSUME_YES )) && return 0
  local answer=""
  read -rp "$1 [Y/n] " answer
  # bash 5.3 misparses an =~ regex ending in "]" before "]]"; glob instead
  [[ ${answer:-y} != [Nn]* ]]
}

confirm "Reset everything and simulate a fresh CyberGhost plugin install?" || {
  echo "Aborted."
  exit 0
}

# ---------------------------------------------------------------------------
step "Disconnecting any live VPN tunnel"
qs ipc call "$PLUGIN_ID" disconnect >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  connected=$(python3 "$REPO_DIR/cyberghost_runner.py" status --json 2>/dev/null |
    jq -r '.connected // empty' || true)
  [[ $connected == "false" ]] && break
  sleep 0.5
done
if [[ ${connected:-} == "true" ]]; then
  echo "WARNING: tunnel still up — disconnect manually before continuing." >&2
  exit 1
fi
ok "tunnel down"

# ---------------------------------------------------------------------------
step "Removing plugin from Omarchy"
omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
# Non-git copies get backed up instead of deleted by `plugin remove`; sweep both.
omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null 2>&1 || true
rm -rf "$PLUGINS_DIR/$PLUGIN_ID" "$PLUGINS_DIR"/."$PLUGIN_ID".bak.*
ok "widget removed from bar and plugins dir"

# ---------------------------------------------------------------------------
step "Removing Polkit rule"
sudo rm -f "$POLKIT_RULE" && ok "polkit rule removed (password prompts return)"

# ---------------------------------------------------------------------------
step "Removing CyberGhost account credentials/state"
rm -rf "$HOME/.cyberghost"
ok "~/.cyberghost wiped (account unlinked)"

# ---------------------------------------------------------------------------
if (( PURGE_DEPS )); then
  step "Uninstalling dependencies (bare-machine simulation)"
  if sudo pacman -Rns --noconfirm wireguard-tools python-requests >/dev/null 2>&1; then
    ok "wireguard-tools + python-requests removed"
  else
    echo "- still needed by other packages; wizard will show them installed"
  fi
fi

# ---------------------------------------------------------------------------
if (( FROM_LOCAL )); then
  step "Installing local checkout into plugins directory"
  mkdir -p "$PLUGINS_DIR"
  rm -rf "$PLUGINS_DIR/$PLUGIN_ID"
  cp -a "$REPO_DIR" "$PLUGINS_DIR/$PLUGIN_ID"
  rm -rf "$PLUGINS_DIR/$PLUGIN_ID/__pycache__"
else
  step "Adding plugin from GitHub (as an external user would)"
  omarchy plugin add "$PLUGIN_URL" --yes
fi

section=$(jq -r '.barWidget.defaultSection // "right"' "$PLUGINS_DIR/$PLUGIN_ID/manifest.json")
omarchy plugin enable "$PLUGIN_ID" "$section"

# ---------------------------------------------------------------------------
step "Restarting shell"
omarchy restart shell

printf '\n%s\n' "${GREEN}Fresh state restored.${NC}"
cat <<DONE

Now finish as a brand-new user — everything through the WIDGET, no terminal:

  1. Click the ghost icon in the bar (${section} section).
  2. The FIRST-RUN SETUP panel appears. Use its buttons:
       - Install        -> wireguard-tools + python-requests (pkexec prompt)
       - Link account   -> your CyberGhost username/password
       - Enable         -> optional passwordless connect (Polkit rule)
  3. Once every checklist item is green, the full panel unlocks:
     connect, pick countries, server modes, protocols.

DONE

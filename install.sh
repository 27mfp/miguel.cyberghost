#!/usr/bin/env bash
# CyberGhost VPN plugin for Omarchy — guided setup, reset and uninstall.
#
# Usage: bash install.sh [MODE] [OPTIONS]
#
# Modes:
#   (default)      guided dependency check and account link
#   --fresh        destructive developer reset: remove plugin state, then
#                  reinstall from this checkout (--local) or from GitHub
#   --uninstall    remove the plugin, its native credentials and recognized
#                  pre-1.7 files; the vendor CLI config is preserved
#
# Options:
#   --dry-run      print what would run, without changing anything
#   --local        with --fresh: install this checkout instead of cloning
#   --purge-deps   with --fresh/--uninstall: also uninstall python-requests
#   -y, --yes      answer yes to prompts (never implied by --dry-run)
#   -h, --help     show this help
#
# Every mode asks before changing anything; EOF and blank input refuse.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="miguel.cyberghost"
PLUGIN_URL="https://github.com/27mfp/miguel.cyberghost.git"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
RUNNER="$DIR/cyberghost_runner.py"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

MODE="guided"
DRY_RUN=0
ASSUME_YES=0
FROM_LOCAL=0
PURGE_DEPS=0
STAGE_ROOT=""
SOURCE_DIR=""

say() { printf "%b\n" "$1"; }
step() { printf "\n${BOLD}==> %s${NC}\n" "$1"; }
ok() { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$1" >&2; }

usage() {
  # The header is the contiguous comment block from line 2 through this marker.
  sed -n '2,/^# Every mode asks/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cleanup() {
  if [[ -n "${STAGE_ROOT:-}" && -d "$STAGE_ROOT" ]]; then
    rm -rf -- "$STAGE_ROOT"
  fi
}
trap cleanup EXIT

run() {
  if ((DRY_RUN)); then
    printf "${DIM}would run:${NC} %s\n" "$*"
    return 0
  fi
  "$@"
}

# Installation and reset change the system, so only an explicit yes proceeds.
# EOF, blank input and arbitrary text are refusals.
confirm() {
  ((ASSUME_YES)) && return 0
  if ((DRY_RUN)); then
    say "${DIM}would ask:${NC} $1 [y/N] "
    return 0
  fi
  local answer=""
  read -rp "$1 [y/N] " answer || return 1
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "$1 is required; install it before starting (for example: sudo pacman -S $1)."
    exit 1
  }
}

have_pacman_pkg_installed() {
  /usr/bin/pacman -Qq "$1" >/dev/null 2>&1
}

install_pacman() {
  local pkg="$1"
  if have_pacman_pkg_installed "$pkg"; then
    ok "$pkg already installed"
    return 0
  fi
  if confirm "Install '$pkg' via pacman?"; then
    run /usr/bin/sudo /usr/bin/pacman -S --needed "$pkg"
  else
    warn "skipped $pkg"
    return 1
  fi
}

# ---- Shared lifecycle helpers -------------------------------------------------

tunnel_is_connected() {
  local output
  output=$(/usr/bin/python3 "$RUNNER" status --json 2>/dev/null) || return 2
  printf '%s' "$output" | /usr/bin/python3 -c '
import json
import sys

data = json.load(sys.stdin)
connected = data.get("connected")
if not isinstance(connected, bool):
    raise SystemExit("missing boolean connected state")
print("true" if connected else "false")
'
}

wait_for_tunnel_down() {
  if ((DRY_RUN)); then
    say "${DIM}would wait for the tunnel to go down${NC}"
    return 0
  fi
  local attempt connected
  qs ipc call "$PLUGIN_ID" disconnect >/dev/null 2>&1 || true
  for ((attempt = 0; attempt < 30; attempt++)); do
    if ! connected=$(tunnel_is_connected); then
      warn "status verification failed — disconnect manually before continuing."
      return 1
    fi
    [[ "$connected" == "false" ]] && return 0
    sleep 0.5
  done
  warn "could not verify that the tunnel is down — disconnect manually before continuing."
  return 1
}

legacy_files_present() {
  /usr/bin/python3 "$RUNNER" check 2>/dev/null | /usr/bin/python3 -c '
import json
import sys

data = json.load(sys.stdin)
print("1" if data.get("legacy_helper") or data.get("legacy_polkit_rule") else "0")
'
}

remove_legacy_helper() {
  local strict="${1:-}"
  local force="${2:-}"
  local legacy
  legacy=$(legacy_files_present) || return 0
  [[ "$legacy" == 1 ]] || return 0
  if ((force)) || confirm "Remove the old root helper and Polkit rule from a previous release?"; then
    run /usr/bin/bash "$DIR/scripts/remove-legacy-helper.sh" "$strict"
  fi
}

remove_plugin_registration() {
  if ((DRY_RUN)); then
    say "${DIM}would disable and remove $PLUGIN_ID from Omarchy${NC}"
    say "${DIM}would remove $PLUGINS_DIR/$PLUGIN_ID${NC}"
    return 0
  fi
  omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null 2>&1 || true
  # Remove only the fixed plugin target. Do not sweep unrelated Omarchy backups.
  rm -rf -- "${PLUGINS_DIR:?}/$PLUGIN_ID"
}

remove_native_credentials() {
  run rm -f -- "$HOME/.cyberghost/native.ini"
  say "Native credentials removed. Legacy config.ini is preserved and may still provide account access."
}

purge_dependencies() {
  ((PURGE_DEPS)) || return 0
  step "Uninstalling dependencies (bare-machine simulation)"
  if ((DRY_RUN)); then
    say "${DIM}would uninstall python-requests${NC}"
    return 0
  fi
  if /usr/bin/sudo /usr/bin/pacman -Rns --noconfirm python-requests >/dev/null 2>&1; then
    ok "python-requests removed"
  else
    say "- still needed by other packages; the wizard will show them installed"
  fi
}

restart_shell() {
  if ((DRY_RUN)); then
    say "${DIM}would restart the Omarchy shell${NC}"
    return 0
  fi
  omarchy restart shell
}

stage_replacement() {
  step "Staging replacement plugin"
  if ((DRY_RUN)); then
    if ((FROM_LOCAL)); then
      say "${DIM}would stage $DIR into $PLUGINS_DIR/$PLUGIN_ID${NC}"
    else
      say "${DIM}would clone $PLUGIN_URL into $PLUGINS_DIR/$PLUGIN_ID${NC}"
    fi
    return 0
  fi
  require_tool jq
  STAGE_ROOT=$(/usr/bin/mktemp -d /tmp/cyberghost-fresh.XXXXXX)
  SOURCE_DIR="$STAGE_ROOT/$PLUGIN_ID"
  mkdir -p "$SOURCE_DIR"
  if ((FROM_LOCAL)); then
    cp -a "$DIR"/. "$SOURCE_DIR"/
  else
    GIT_TERMINAL_PROMPT=0 /usr/bin/git clone --depth 1 -- "$PLUGIN_URL" "$SOURCE_DIR"
  fi
  /usr/bin/jq -e --arg id "$PLUGIN_ID" '.id == $id and .entryPoints.barWidget == "BarWidget.qml"' \
    "$SOURCE_DIR/manifest.json" >/dev/null
  if command -v omarchy-plugin-validate >/dev/null 2>&1; then
    omarchy-plugin-validate "$SOURCE_DIR"
  fi
  rm -rf -- "$SOURCE_DIR/__pycache__"
  ok "replacement staged and manifest validated"
}

# ---- Modes -------------------------------------------------------------------

guided_setup() {
  say "CyberGhost VPN plugin — setup"

  # 1. System packages. The tunnel itself is a NetworkManager connection, so
  # no WireGuard tools, resolvconf provider or root helper are needed.
  if /usr/bin/python3 -c 'import requests' >/dev/null 2>&1; then
    ok "python-requests already installed"
  else
    install_pacman python-requests || true
  fi

  # 2. CyberGhost account link (native, no CLI required)
  setup_account || true

  # 3. Previous-release cleanup
  remove_legacy_helper || true

  # 4. Report
  summary
}

setup_account() {
  if /usr/bin/python3 "$RUNNER" check 2>/dev/null | /usr/bin/python3 -c '
import json
import sys

sys.exit(0 if json.load(sys.stdin).get("credentials") else 1)
'; then
    ok "Native or compatible legacy credentials are ready"
    return 0
  fi
  say "→ No CyberGhost credentials found."
  if confirm "Link your CyberGhost account now (native, no CLI needed)?"; then
    run /usr/bin/python3 "$RUNNER" register && return 0
  fi
  say "${YELLOW}⚠${NC} link later from the widget's setup panel, or run: ${DIM}python3 $RUNNER register${NC}"
  return 1
}

summary() {
  say ""
  say "── Readiness check ──────────────────────────"
  local status_json="{}"
  if ((DRY_RUN)); then
    say "${DIM}would read readiness from cyberghost_runner.py check${NC}"
  else
    status_json=$(/usr/bin/python3 "$RUNNER" check 2>/dev/null || echo "{}")
  fi
  STATUS_JSON="$status_json" /usr/bin/python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ.get("STATUS_JSON", "{}"))

    def tick(key):
        return "\033[0;32m✓\033[0m" if data.get(key) else "\033[1;33m✗\033[0m"

    print(f" {tick('nm')} NetworkManager running")
    permission = data.get("nm_permission") or "unknown"
    mark = "\033[0;32m✓\033[0m" if permission in ("yes", "auth") else "\033[1;33m✗\033[0m"
    print(f" {mark} Network permission ({permission})")
    print(f" {tick('requests')} Python requests (key negotiation)")
    print(f" {tick('credentials')} CyberGhost account credentials")
    if data.get("legacy_helper") or data.get("legacy_polkit_rule"):
        print(" \033[1;33m!\033[0m Old root helper still installed (bash scripts/remove-legacy-helper.sh)")
except Exception:
    print(" Check status unavailable")
PY
  say "─────────────────────────────────────────────"
  say ""
  say "Done. The bar widget is managed by Omarchy (${DIM}omarchy plugin enable $PLUGIN_ID${NC} if needed)."
}

fresh_install() {
  # Stage and validate the replacement before any installed files are removed.
  # This also makes --local safe when the script itself runs from the
  # installed plugin directory.
  stage_replacement

  step "Disconnecting any live VPN tunnel"
  wait_for_tunnel_down || exit 1
  ok "tunnel down"

  step "Removing recognized legacy helper files before plugin teardown"
  # Use the same recognizers as ordinary migration. Authorization failure or an
  # unrecognized helper/rule aborts before the installed plugin is removed.
  if ((DRY_RUN)); then
    say "${DIM}would run scripts/remove-legacy-helper.sh --yes --strict${NC}"
  else
    /usr/bin/bash "$SOURCE_DIR/scripts/remove-legacy-helper.sh" --yes --strict
  fi
  ok "legacy cleanup completed; ambiguous WireGuard configuration preserved"

  step "Removing plugin from Omarchy"
  remove_plugin_registration
  ok "widget removed from bar and plugins dir"

  step "Removing native plugin credentials (preserving the vendor CLI)"
  remove_native_credentials

  purge_dependencies

  step "Installing staged plugin into plugins directory"
  if ((DRY_RUN)); then
    say "${DIM}would install the staged plugin and enable it in the bar${NC}"
  else
    mkdir -p "$PLUGINS_DIR"
    rm -rf -- "${PLUGINS_DIR:?}/$PLUGIN_ID"
    mv -- "$SOURCE_DIR" "${PLUGINS_DIR:?}/$PLUGIN_ID"
    SOURCE_DIR=""
    omarchy shell rescanPlugins >/dev/null 2>&1 || true
    local section
    section=$(/usr/bin/jq -r '.barWidget.defaultSection // "right"' "$PLUGINS_DIR/$PLUGIN_ID/manifest.json")
    omarchy plugin enable "$PLUGIN_ID" "$section"
  fi

  step "Restarting shell"
  restart_shell

  say ""
  say "${GREEN}Fresh state restored.${NC}"
  cat <<DONE

Now finish as a brand-new user through the WIDGET:

  1. Click the ghost icon in the bar (right section by default).
  2. The FIRST-RUN SETUP panel appears. Use its buttons:
       - Install        -> python-requests in Omarchy's floating terminal (only if missing)
       - Link account   -> your CyberGhost username/password
       - Recheck        -> optional; the panel rechecks when the terminal closes
  3. Once the account is linked, the full panel unlocks. Connections are
     NetworkManager profiles; no root helper or password prompt is involved.

DONE
}

uninstall() {
  step "Disconnecting any live VPN tunnel"
  wait_for_tunnel_down || exit 1
  ok "tunnel down"

  step "Removing recognized pre-1.7 files"
  remove_legacy_helper "" 1 || {
    warn "legacy cleanup failed; the plugin was left installed."
    exit 1
  }

  step "Removing plugin from Omarchy"
  remove_plugin_registration
  ok "widget removed from bar and plugins dir"

  step "Removing native plugin credentials (preserving the vendor CLI)"
  remove_native_credentials

  purge_dependencies

  restart_shell
  say ""
  say "${GREEN}CyberGhost VPN removed.${NC}"
  say "The vendor CLI config (~/.cyberghost/config.ini) was kept; delete it yourself if it is obsolete."
}

# ---- Argument parsing --------------------------------------------------------

while (($#)); do
  case "$1" in
    --fresh) MODE="fresh" ;;
    --uninstall) MODE="uninstall" ;;
    --dry-run) DRY_RUN=1 ;;
    --local) FROM_LOCAL=1 ;;
    --purge-deps) PURGE_DEPS=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    --github) say "--github is now the default; use --local for the local checkout" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      echo "Try: bash install.sh --help" >&2
      exit 1
      ;;
  esac
  shift
done

if ((DRY_RUN)); then
  say "${YELLOW}Dry run:${NC} no system, plugin or account state will change."
fi

case "$MODE" in
  guided) guided_setup ;;
  fresh)
    confirm "Reset everything and simulate a fresh CyberGhost plugin install?" || {
      echo "Aborted."
      exit 0
    }
    fresh_install
    ;;
  uninstall)
    confirm "Remove the CyberGhost VPN plugin, its native credentials and recognized legacy files?" || {
      echo "Aborted."
      exit 0
    }
    uninstall
    ;;
esac

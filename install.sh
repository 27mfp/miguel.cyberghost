#!/usr/bin/env bash
# CyberGhost VPN plugin for Omarchy — guided dependency installer.
#
# Usage:  bash install.sh
# Safe to re-run (idempotent); every step asks before changing anything.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'

say() { printf "%b\n" "$1"; }

confirm() {
  local answer=""
  read -rp "$1 [Y/n] " answer
  # bash 5.3 misparses an =~ regex ending in "]" before "]]"; glob instead
  [[ ${answer:-y} != [Nn]* ]]
}

have_pacman_pkg_installed() {
  /usr/bin/pacman -Qq "$1" >/dev/null 2>&1
}

install_pacman() {
  local pkg="$1"
  if have_pacman_pkg_installed "$pkg"; then
    say "${GREEN}✓${NC} $pkg already installed"
    return 0
  fi
  if confirm "Install '$pkg' via pacman?"; then
    /usr/bin/sudo /usr/bin/pacman -S --needed "$pkg"
  else
    say "${YELLOW}⚠${NC} skipped $pkg"
    return 1
  fi
}

install_cyberghost_cli() {
  if command -v cyberghostvpn >/dev/null 2>&1; then
    say "${GREEN}✓${NC} cyberghostvpn CLI already installed"
    return 0
  fi
  local helper=""
  command -v yay >/dev/null 2>&1 && helper="yay"
  command -v paru >/dev/null 2>&1 && helper="paru"
  echo "→ The cyberghostvpn CLI is RECOMMENDED (live server inventory/manual selection and"
  echo "  required for OpenVPN / torrent / streaming modes — account linking remains native)."
  if [[ -z $helper ]]; then
    say "${DIM}- no AUR helper found (yay/paru) — skip or install the CLI manually later"
    return 1
  fi
  say "${DIM}- this is an optional third-party AUR package; review its PKGBUILD and trust it before continuing"
  if confirm "Install 'cyberghostvpn' via $helper?"; then
    "$helper" -S --needed cyberghostvpn
  else
    say "${DIM}- skipped cyberghostvpn CLI (native fallback remains available, but the CLI is recommended)"
    return 1
  fi
}

install_polkit_rule() {
  if ! confirm "Install the required root helper?"; then
    say "${DIM}- skipped root helper (connect is disabled until the helper is installed)${NC}"
    return 0
  fi

  if confirm "Also install the optional Polkit rule for passwordless connect/disconnect?"; then
    bash "$DIR/install-helper.sh"
    say "${GREEN}✓${NC} Root helper and optional Polkit rule installed"
  else
    bash "$DIR/install-helper.sh" --no-polkit-rule
    say "${GREEN}✓${NC} Root helper installed; Polkit authorization remains enabled"
  fi
}

setup_account() {
  if [[ -f "$HOME/.cyberghost/config.ini" ]]; then
    say "${GREEN}✓${NC} CyberGhost credentials found (~/.cyberghost/config.ini)"
    return 0
  fi
  say "→ No CyberGhost credentials found."
  if confirm "Link your CyberGhost account now (native, no CLI needed)?"; then
    /usr/bin/python3 "$DIR/cyberghost_runner.py" register && return 0
  fi
  say "${YELLOW}⚠${NC} link later from the widget's setup panel, or run: ${DIM}python3 $DIR/cyberghost_runner.py register${NC}"
  return 1
}

summary() {
  say ""
  say "── Readiness check ──────────────────────────"
  local status_json
  status_json=$(/usr/bin/python3 "$DIR/cyberghost_runner.py" check 2>/dev/null || echo "{}")
  STATUS_JSON="$status_json" /usr/bin/python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ.get("STATUS_JSON", "{}"))
    def tick(key):
        return "\033[0;32m✓\033[0m" if data.get(key) else "\033[1;33m✗\033[0m"
    print(f" {tick('wg_tools')} WireGuard tools (wg-quick)")
    print(f" {tick('requests')} Python requests (key negotiation)")
    print(f" {tick('credentials')} CyberGhost account credentials")
    print(f" {tick('helper_installed')} Root helper binary (/usr/local/bin/cyberghost-runner)")
    print(f" {tick('polkit_rule_installed')} Polkit rule (50-cyberghost.rules)")
    cli_status = "\033[0;32m✓\033[0m" if data.get("cli") else "\033[2m- (recommended, WireGuard/OpenVPN/streaming)\033[0m"
    print(f" {cli_status} cyberghostvpn CLI")
except Exception:
    print(" Check status unavailable")
PY
  say "─────────────────────────────────────────────"
  say ""
  say "Done. The bar widget is managed by Omarchy (${DIM}omarchy plugin enable miguel.cyberghost${NC} if needed)."
}

say "CyberGhost VPN plugin — setup"

# 1. System packages
install_pacman wireguard-tools || true
if /usr/bin/python3 -c 'import requests' >/dev/null 2>&1; then
  say "${GREEN}✓${NC} python-requests already installed"
else
  install_pacman python-requests || true
fi

# 2. CyberGhost CLI (AUR) + account link
install_cyberghost_cli || true
setup_account || true

# 3. Passwordless privilege escalation
install_polkit_rule

# 4. Report
summary

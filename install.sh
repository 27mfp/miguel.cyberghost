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
  [[ ${answer:-y} =~ ^[Nn] ]]
}

have_pacman_pkg_installed() {
  pacman -Qq "$1" >/dev/null 2>&1
}

install_pacman() {
  local pkg="$1"
  if have_pacman_pkg_installed "$pkg"; then
    say "${GREEN}✓${NC} $pkg already installed"
    return 0
  fi
  if confirm "Install '$pkg' via pacman?"; then
    sudo pacman -S --needed "$pkg"
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
  if [[ -z $helper ]]; then
    say "${YELLOW}⚠${NC} no AUR helper found (yay/paru) — install the cyberghostvpn CLI manually"
    return 1
  fi
  if confirm "Install 'cyberghostvpn' via $helper? (needed once for account setup; required for OpenVPN/torrent/streaming)"; then
    "$helper" -S --needed cyberghostvpn
  else
    say "${YELLOW}⚠${NC} skipped cyberghostvpn CLI"
    return 1
  fi
}

install_polkit_rule() {
  if confirm "Install Polkit rule for passwordless connect/disconnect?"; then
    sudo cp "$DIR/50-cyberghost.rules" /etc/polkit-1/rules.d/
    say "${GREEN}✓${NC} Polkit rule installed"
  else
    say "${DIM}- skipped Polkit rule (pkexec will ask for your password on connect)${NC}"
  fi
}

setup_account() {
  if [[ -f "$HOME/.cyberghost/config.ini" ]]; then
    say "${GREEN}✓${NC} CyberGhost credentials found (~/.cyberghost/config.ini)"
    return 0
  fi
  say "→ No CyberGhost credentials found. One-time account link:"
  if confirm "Run 'sudo cyberghostvpn --setup' now?"; then
    sudo cyberghostvpn --setup && return 0
  fi
  say "${YELLOW}⚠${NC} run ${DIM}sudo cyberghostvpn --setup${NC} later, or place token/secret in ~/.cyberghost/config.ini"
  return 1
}

summary() {
  say ""
  say "── Readiness check ──────────────────────────"
  python3 "$DIR/cyberghost_runner.py" check --json || true
  say "─────────────────────────────────────────────"
  say ""
  say "Done. The bar widget is managed by Omarchy (${DIM}omarchy plugin enable miguel.cyberghost${NC} if needed)."
}

say "CyberGhost VPN plugin — setup"

# 1. System packages
install_pacman wireguard-tools || true
if python3 -c 'import requests' >/dev/null 2>&1; then
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

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
  # EOF, blank input and arbitrary text are refusals. Installation changes
  # require an explicit affirmative response.
  read -rp "$1 [y/N] " answer || return 1
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
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

remove_legacy_helper() {
  # Releases before 1.7 installed a root helper; NetworkManager replaces it.
  local legacy
  legacy=$(/usr/bin/python3 "$DIR/cyberghost_runner.py" check | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if d.get("legacy_helper") or d.get("legacy_polkit_rule") else 0)')
  [[ "$legacy" == 1 ]] || return 0
  if confirm "Remove the old root helper and Polkit rule from a previous release?"; then
    bash "$DIR/scripts/remove-legacy-helper.sh"
  fi
}

setup_account() {
  if /usr/bin/python3 "$DIR/cyberghost_runner.py" check | /usr/bin/python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("credentials") else 1)'; then
    say "${GREEN}✓${NC} Native or compatible legacy credentials are ready"
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
  say "Done. The bar widget is managed by Omarchy (${DIM}omarchy plugin enable miguel.cyberghost${NC} if needed)."
}

say "CyberGhost VPN plugin — setup"

# 1. System packages. The tunnel itself is a NetworkManager connection, so
# no WireGuard tools, resolvconf provider or root helper are needed.
if /usr/bin/python3 -c 'import requests' >/dev/null 2>&1; then
  say "${GREEN}✓${NC} python-requests already installed"
else
  install_pacman python-requests || true
fi

# 2. CyberGhost account link (native, no CLI required)
setup_account || true

# 3. Previous-release cleanup
remove_legacy_helper || true

# 4. Report
summary

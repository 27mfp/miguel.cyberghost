#!/usr/bin/env bash
# Explicit opt-in workaround for the Arch vendor CLI's nested sudo lookup.
set -euo pipefail
SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/openvpn-compat.sh"
[[ $EUID != 0 ]] || { echo 'Run as your desktop user; this installer invokes sudo.' >&2; exit 1; }
[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || { echo 'Missing regular compatibility launcher.' >&2; exit 1; }
[[ -x /usr/bin/openvpn ]] || { echo 'Install distribution OpenVPN first.' >&2; exit 1; }
HASH=$(sha256sum -- "$SOURCE")
HASH=${HASH%% *}
echo 'Install /usr/local/bin/openvpn as a root-owned compatibility launcher.'
echo 'It only removes the retired --ncp-disable flag for recognized CyberGhost commands.'
echo 'No sudoers, TLS verification or packaged files will be changed.'
read -r -p 'Install this system-wide command launcher? [y/N]: ' answer
[[ "$answer" == y || "$answer" == Y ]] || exit 0

sudo /usr/bin/bash -s -- "$SOURCE" "$HASH" <<'ROOT'
set -euo pipefail
source=$1
expected=$2
target=/usr/local/bin/openvpn
[[ ! -e "$target" && ! -L "$target" ]] || { echo "Refusing to overwrite $target" >&2; exit 1; }
# Refuse writable/symlinked command-search directories.
for directory in /usr /usr/local /usr/local/bin; do
  [[ -d "$directory" && ! -L "$directory" ]] || exit 1
  [[ $(stat -c %u -- "$directory") == 0 ]] || exit 1
  mode=$(stat -c %a -- "$directory")
  (( (8#$mode & 022) == 0 )) || exit 1
done
stage=$(mktemp -d /usr/local/bin/.cyberghost-compat.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT
install -o root -g root -m 0755 -- "$source" "$stage/openvpn"
actual=$(sha256sum -- "$stage/openvpn")
[[ "${actual%% *}" == "$expected" ]] || { echo 'Launcher changed during authorization; refusing installation.' >&2; exit 1; }
/usr/bin/bash -n "$stage/openvpn"
# Same-filesystem hard link publishes the verified root-owned snapshot without
# ever overwriting a destination created between the check and installation.
ln -T -- "$stage/openvpn" "$target"
echo "Installed $target. Keep /usr/bin/openvpn unchanged."
echo 'To undo: first verify this file is still the installed launcher, then remove only /usr/local/bin/openvpn.'
ROOT

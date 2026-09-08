#!/usr/bin/bash
# CyberGhost CLI 1.4.1 compatibility with OpenVPN >= 2.6.
# Keep the distribution binary and sudo policy unchanged. Only recognize the
# vendor's combined server/auth-file signature; all other invocations pass through.
set -euo pipefail

filter_openvpn_arguments() {
  local previous='' argument has_server=0 has_auth=0
  OPENVPN_ARGUMENTS=()
  for argument in "$@"; do
    if [[ "$previous" == --remote && "$argument" == *.cg-dialup.net ]]; then
      has_server=1
    fi
    if [[ "$previous" == --auth-user-pass && "$argument" == /home/*/.cyberghost/openvpn/auth ]]; then
      has_auth=1
    fi
    previous="$argument"
  done
  for argument in "$@"; do
    if (( has_server && has_auth )) && [[ "$argument" == --ncp-disable ]]; then
      continue
    fi
    OPENVPN_ARGUMENTS+=("$argument")
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  filter_openvpn_arguments "$@"
  exec /usr/bin/openvpn "${OPENVPN_ARGUMENTS[@]}"
fi

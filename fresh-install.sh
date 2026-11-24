#!/usr/bin/env bash
# Deprecated: destructive developer reset moved into install.sh.
#
# This wrapper is kept so existing bookmarks, documentation links and CI jobs
# keep working; it delegates to `install.sh --fresh` (same flags and safety
# checks). It will be removed in the first release after 1.8.0.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf 'fresh-install.sh is deprecated; delegating to install.sh --fresh.\n' >&2
printf 'Update scripts and documentation to use: bash install.sh --fresh\n\n' >&2

exec /usr/bin/bash "$DIR/install.sh" --fresh "$@"

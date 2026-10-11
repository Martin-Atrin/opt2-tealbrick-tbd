#!/bin/bash
# Development build: same assembly as release.sh, signed with a local identity
# (or ad hoc with TBD_SIGN_IDENTITY=-). Build output is deleted with --clean.
set -euo pipefail
TBD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$TBD_ROOT/companion/build.noindex"
if [ "${1:-}" = "--clean" ]; then rm -rf "$DERIVED" "$TBD_ROOT/chat/out"; echo "Removed build output."; exit 0; fi
if ps -axo comm | /usr/bin/grep -Fqx "$DERIVED/Build/Products/Debug/TBD.app/Contents/MacOS/TBD"; then
  echo 'Quit the running TBD development app before rebuilding it.' >&2; exit 1
fi
source "$TBD_ROOT/scripts/assemble.sh"
tbd_assemble Debug "$DERIVED" "$DERIVED/logs"
IDENTITY="${TBD_SIGN_IDENTITY:?set TBD_SIGN_IDENTITY to a local codesigning identity (name, SHA-1, or - for ad hoc)}"
for helper in "$TBD_APP"/Contents/Helpers/*; do codesign --force --sign "$IDENTITY" --timestamp=none "$helper"; done
codesign --force --sign "$IDENTITY" --timestamp=none "$TBD_APP/Contents/Resources/Chat/node"
codesign --force --sign "$IDENTITY" --timestamp=none "$TBD_APP/Contents/Resources/Chat/claude"
codesign --force --sign "$IDENTITY" --timestamp=none "$TBD_APP"
codesign --verify --strict "$TBD_APP"
printf 'Built: %s\n' "$TBD_APP"

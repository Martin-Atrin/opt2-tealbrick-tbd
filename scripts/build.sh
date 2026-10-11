#!/bin/bash
set -euo pipefail
TBD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TBD_NODE_SOURCE="${TBD_NODE_SOURCE:?set TBD_NODE_SOURCE to an official arm64 Node 24 binary}"
if ps -axo comm | /usr/bin/grep -Fx "$TBD_ROOT/companion/build.noindex/Build/Products/Debug/TBD.app/Contents/MacOS/TBD"; then
  echo 'Quit the running TBD development app before rebuilding its signed bundle.' >&2
  exit 1
fi
cd "$TBD_ROOT/chat"
node scripts/build-tbd.mjs
npm run typecheck
cd "$TBD_ROOT"
xcodebuild -project companion/Dayflow/Dayflow.xcodeproj -scheme Dayflow -configuration Debug -derivedDataPath companion/build.noindex -skipMacroValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build > docs/native-integration-build.log 2>&1
xcodebuild -project companion/Dayflow/Dayflow.xcodeproj -scheme macparakeet-cli -configuration Debug -derivedDataPath companion/build.noindex -skipMacroValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build > docs/listening-cli-build.log 2>&1
TBD_APP="$TBD_ROOT/companion/build.noindex/Build/Products/Debug/TBD.app"
mkdir -p "$TBD_APP/Contents/Resources/Chat"
rsync -a --delete "$TBD_ROOT/chat/out/tbd/" "$TBD_APP/Contents/Resources/Chat/"
ditto "$TBD_NODE_SOURCE" "$TBD_APP/Contents/Resources/Chat/node"
chmod +x "$TBD_APP/Contents/Resources/Chat/node"
mkdir -p "$TBD_APP/Contents/Helpers" "$TBD_APP/Contents/Resources/Licenses"
cp "$TBD_ROOT/companion/build.noindex/Build/Products/Debug/macparakeet-cli" "$TBD_APP/Contents/Helpers/macparakeet-cli"
cp "$TBD_ROOT/listening/LICENSE" "$TBD_APP/Contents/Resources/Licenses/MacParakeet-GPL-3.0.txt"
cp "$TBD_ROOT/companion/LICENSE" "$TBD_APP/Contents/Resources/Licenses/Companion-MIT.txt"
# Keep development signing stable for TCC and Keychain on this workstation.
TBD_IDENTITY="${TBD_SIGN_IDENTITY:?set TBD_SIGN_IDENTITY to a local codesigning identity (name or SHA-1)}"
codesign --force --sign "$TBD_IDENTITY" --timestamp=none "$TBD_APP/Contents/Resources/Chat/node"
codesign --force --deep --sign "$TBD_IDENTITY" --timestamp=none "$TBD_APP"
codesign --verify --deep --strict "$TBD_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$TBD_APP"
printf 'Built and verified: %s\n' "$TBD_APP"

#!/bin/bash
# Build a Developer ID-signed, hardened-runtime Release of TBD.app and,
# when a notary keychain profile is configured, notarize and staple it.
#
# The dev build path (scripts/build.sh, companion/build.noindex, Debug) is
# untouched. Release output lives in companion/build.release.noindex.
#
# Env:
#   TBD_RELEASE_IDENTITY  codesign identity (default: the first "Developer ID Application" identity in the keychain)
#   TBD_RELEASE_TEAM      expected Team ID for the signature check (default: parsed from identity)
#   TBD_NOTARY_PROFILE    notarytool keychain profile; unset = build + sign only, then print setup steps
#   TBD_NODE_SOURCE       Node binary bundled as the Chat helper (same default as build.sh)
set -euo pipefail

TBD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TBD_NODE_SOURCE="${TBD_NODE_SOURCE:?set TBD_NODE_SOURCE to an official arm64 Node 24 binary}"
IDENTITY="${TBD_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "release.sh: no Developer ID Application identity in the keychain" >&2; exit 1; }
TEAM="${TBD_RELEASE_TEAM:-}"
if [ -z "$TEAM" ]; then
  TEAM="$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
  [ -n "$TEAM" ] || { echo "release.sh: cannot parse Team ID; set TBD_RELEASE_TEAM" >&2; exit 1; }
fi
ENT="$TBD_ROOT/scripts/entitlements"
DERIVED="$TBD_ROOT/companion/build.release.noindex"
PRODUCTS="$DERIVED/Build/Products/Release"
APP="$PRODUCTS/TBD.app"
DIST="$DERIVED/dist"
LOGS="$DERIVED/logs"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }

security find-identity -v -p codesigning | /usr/bin/grep -Fq "$IDENTITY" \
  || [ "${#IDENTITY}" -eq 40 ] \
  || die "signing identity not found in keychain: $IDENTITY"
[ -x "$TBD_NODE_SOURCE" ] || die "node helper source missing: $TBD_NODE_SOURCE"
if ps -axo comm | /usr/bin/grep -Fxq "$APP/Contents/MacOS/TBD"; then
  die "quit the running release build ($APP) before rebuilding it"
fi
mkdir -p "$LOGS" "$DIST"

step "Chat bundle"
cd "$TBD_ROOT/chat"
node scripts/build-tbd.mjs
npm run typecheck
cd "$TBD_ROOT"

step "xcodebuild Release (logs: $LOGS)"
# Signing is done below, inside-out, with explicit entitlements. arm64 only:
# the bundled node helper is a thin arm64 binary.
XCB=(-project companion/Dayflow/Dayflow.xcodeproj -configuration Release -derivedDataPath "$DERIVED"
  -skipMacroValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
rm -rf "$APP"
xcodebuild "${XCB[@]}" -scheme Dayflow build > "$LOGS/app-build.log" 2>&1 \
  || { tail -40 "$LOGS/app-build.log"; die "app build failed"; }
xcodebuild "${XCB[@]}" -scheme macparakeet-cli build > "$LOGS/cli-build.log" 2>&1 \
  || { tail -40 "$LOGS/cli-build.log"; die "macparakeet-cli build failed"; }
[ -d "$APP" ] || die "expected app at $APP"

step "Assemble helpers and licenses"
mkdir -p "$APP/Contents/Resources/Chat" "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
rsync -a --delete "$TBD_ROOT/chat/out/tbd/" "$APP/Contents/Resources/Chat/"
ditto "$TBD_NODE_SOURCE" "$APP/Contents/Resources/Chat/node"
chmod +x "$APP/Contents/Resources/Chat/node"
cp "$PRODUCTS/macparakeet-cli" "$APP/Contents/Helpers/macparakeet-cli"
cp "$TBD_ROOT/listening/LICENSE" "$APP/Contents/Resources/Licenses/MacParakeet-GPL-3.0.txt"
cp "$TBD_ROOT/companion/LICENSE" "$APP/Contents/Resources/Licenses/Companion-MIT.txt"

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"
printf 'TBD %s (build %s), %s\n' "$VERSION" "$BUILD" "$BUNDLE_ID"

step "Sign inside-out with: $IDENTITY"
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  SV="$SPARKLE/Versions/B"
  # Per Sparkle's Developer ID guidance; Downloader keeps its own sandbox entitlements.
  if [ -d "$SV/XPCServices/Downloader.xpc" ]; then sign --preserve-metadata=entitlements "$SV/XPCServices/Downloader.xpc"; fi
  if [ -d "$SV/XPCServices/Installer.xpc" ]; then sign "$SV/XPCServices/Installer.xpc"; fi
  if [ -f "$SV/Autoupdate" ]; then sign "$SV/Autoupdate"; fi
  if [ -d "$SV/Updater.app" ]; then sign "$SV/Updater.app"; fi
  sign "$SPARKLE"
fi
for fw in "$APP"/Contents/Frameworks/*.framework; do
  if [ -d "$fw" ] && [ "$fw" != "$SPARKLE" ]; then sign "$fw"; fi
done
for lib in "$APP"/Contents/Frameworks/*.dylib; do
  if [ -f "$lib" ]; then sign "$lib"; fi
done
for helper in "$APP"/Contents/Helpers/*; do
  if [ -f "$helper" ]; then sign --entitlements "$ENT/helper.entitlements" "$helper"; fi
done
sign --entitlements "$ENT/node.entitlements" "$APP/Contents/Resources/Chat/node"
sign --entitlements "$ENT/TBD.entitlements" "$APP"

step "Verify signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
# Every Mach-O in the bundle must carry our team, the hardened runtime, a
# secure timestamp, and no get-task-allow; anything unsigned or foreign fails.
bad=0
while IFS= read -r -d '' f; do
  file -b "$f" | /usr/bin/grep -q '^Mach-O' || continue
  info="$(codesign -dvv "$f" 2>&1 || true)"
  rel="${f#"$APP"/}"
  printf '%s' "$info" | /usr/bin/grep -q "^TeamIdentifier=$TEAM$" || { echo "wrong/missing team: $rel"; bad=1; }
  printf '%s' "$info" | /usr/bin/grep -q 'flags=.*(runtime)' || { echo "no hardened runtime: $rel"; bad=1; }
  printf '%s' "$info" | /usr/bin/grep -q '^Timestamp=' || { echo "no secure timestamp: $rel"; bad=1; }
  if codesign -d --entitlements - --xml "$f" 2>/dev/null | /usr/bin/grep -q 'get-task-allow'; then
    echo "get-task-allow present: $rel"; bad=1
  fi
done < <(find "$APP" -type f -print0)
[ "$bad" -eq 0 ] || die "signature audit failed"
echo "All Mach-O files: team $TEAM, hardened runtime, timestamped."

# Don't let LaunchServices prefer this copy over the installed app for the
# bundle id or the tealbrick-tbd:// URL scheme.
"$LSREGISTER" -u "$APP" 2>/dev/null || true

ZIP="$DIST/TBD-$VERSION-$BUILD.zip"
step "Package $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -z "${TBD_NOTARY_PROFILE:-}" ]; then
  step "Gatekeeper (expected: rejected until notarized)"
  spctl -a -vvv -t exec "$APP" 2>&1 || true
  cat <<EOF

Signed, unnotarized build ready:
  app: $APP
  zip: $ZIP

Notarization skipped: TBD_NOTARY_PROFILE is not set. One-time setup (you
type the app-specific password from appleid.apple.com when prompted; it is
stored in your login keychain, never in this repo):

  xcrun notarytool store-credentials tbd-notary --apple-id <your-apple-id> --team-id $TEAM

Then notarize, staple and package:

  TBD_NOTARY_PROFILE=tbd-notary scripts/release.sh
EOF
  exit 0
fi

step "Notarize via keychain profile '$TBD_NOTARY_PROFILE' (waits)"
NOTARY_OUT="$LOGS/notarytool-submit.txt"
xcrun notarytool submit "$ZIP" --keychain-profile "$TBD_NOTARY_PROFILE" --wait 2>&1 | tee "$NOTARY_OUT"
if ! /usr/bin/grep -q 'status: Accepted' "$NOTARY_OUT"; then
  sub="$(sed -n 's/^ *id: //p' "$NOTARY_OUT" | head -1)"
  die "notarization not accepted; inspect: xcrun notarytool log ${sub:-<submission-id>} --keychain-profile $TBD_NOTARY_PROFILE"
fi

step "Staple and assess"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP"
"$LSREGISTER" -u "$APP" 2>/dev/null || true

step "Package stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
DMG="$DIST/TBD-$VERSION-$BUILD.dmg"
STAGE="$DERIVED/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/TBD.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TBD $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
printf '\nNotarized and stapled:\n  app: %s\n  zip: %s\n  dmg: %s\n' "$APP" "$ZIP" "$DMG"

#!/bin/bash
# Build a Developer ID-signed, hardened-runtime Release of TBD.app and,
# when a notary keychain profile is configured, notarize and staple it.
#
# One pipeline: scripts/assemble.sh builds everything (build.sh uses it too).
# Release output lives in companion/build.release.noindex; delete it after use.
#
# Env:
#   TBD_RELEASE_IDENTITY  codesign identity (default: the first "Developer ID Application" identity in the keychain)
#   TBD_RELEASE_TEAM      expected Team ID for the signature check (default: parsed from identity)
#   TBD_NOTARY_PROFILE    notarytool keychain profile; unset = build + sign only, then print setup steps
#   TBD_NODE_SOURCE       optional Node binary for the Chat helper (default: scripts/fetch-node.sh, pinned official build)
#   TBD_PUBLISH=1         after notarization, publish a GitHub release on Martin-Atrin/opt2-tealbrick-tbd (Coordinator approval required)
set -euo pipefail

TBD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
if ps -axo comm | /usr/bin/grep -Fxq "$APP/Contents/MacOS/TBD"; then
  die "quit the running release build ($APP) before rebuilding it"
fi
mkdir -p "$LOGS" "$DIST"

step "Assemble (chat, app, tbd-listen, helpers; logs: $LOGS)"
rm -rf "$APP"
source "$TBD_ROOT/scripts/assemble.sh"
tbd_assemble Release "$DERIVED" "$LOGS"
[ "$TBD_APP" = "$APP" ] || die "unexpected app path $TBD_APP"

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"
printf 'TBD %s (build %s), %s\n' "$VERSION" "$BUILD" "$BUNDLE_ID"

step "Sign inside-out with: $IDENTITY"
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }

for fw in "$APP"/Contents/Frameworks/*.framework; do
  if [ -d "$fw" ]; then sign "$fw"; fi
done
for lib in "$APP"/Contents/Frameworks/*.dylib; do
  if [ -f "$lib" ]; then sign "$lib"; fi
done
for helper in "$APP"/Contents/Helpers/*; do
  if [ -f "$helper" ]; then sign --entitlements "$ENT/helper.entitlements" "$helper"; fi
done
sign --entitlements "$ENT/node.entitlements" "$APP/Contents/Resources/Chat/node"
# The Claude Agent SDK executable of the default agent (JIT runtime, same entitlements as node).
sign --entitlements "$ENT/node.entitlements" "$APP/Contents/Resources/Chat/claude"
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
( cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "TBD-$VERSION-$BUILD.sha256" )
printf '  sha256: %s\n' "$DIST/TBD-$VERSION-$BUILD.sha256"

if [ "${TBD_PUBLISH:-}" = "1" ]; then
  step "Publish GitHub release v$VERSION on Martin-Atrin/opt2-tealbrick-tbd"
  gh release create "v$VERSION" "$ZIP" "$DMG" "$DIST/TBD-$VERSION-$BUILD.sha256" \
    --repo Martin-Atrin/opt2-tealbrick-tbd --title "TBD $VERSION" --notes "TBD $VERSION (build $BUILD). Notarized, Apple silicon, macOS 14+."
fi

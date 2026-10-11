#!/bin/bash
# Fetch the official Node.js arm64 binary bundled as the Chat helper runtime.
# Pinned version and sha256 (from nodejs.org SHASUMS256.txt); prints the binary path.
set -euo pipefail
NODE_VERSION="v24.21.0"
NODE_SHA256="bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057"
CACHE="${TBD_CACHE:-$HOME/Library/Caches/tbd-build}"
NAME="node-$NODE_VERSION-darwin-arm64"
BIN="$CACHE/$NAME/bin/node"
if [ ! -x "$BIN" ]; then
  mkdir -p "$CACHE"
  TARBALL="$CACHE/$NAME.tar.gz"
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/$NAME.tar.gz" -o "$TARBALL"
  echo "$NODE_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null
  tar -xzf "$TARBALL" -C "$CACHE" "$NAME/bin/node" "$NAME/LICENSE"
  rm -f "$TARBALL"
fi
printf '%s\n' "$BIN"

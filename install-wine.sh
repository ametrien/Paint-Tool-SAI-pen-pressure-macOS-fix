#!/bin/bash
# Download & install Gcenx "Wine Staging" for macOS into /Applications.
# Used by SAI Pen Pressure.app when Wine is missing, and runnable on its own.
#
# Pick a specific build instead of the latest:  WINE_URL="https://…/wine-staging-…-osx64.tar.xz" ./install-wine.sh
set -euo pipefail

DEST="/Applications/Wine Staging.app"
echo "==================================================="
echo "  Wine Staging installer for macOS (Gcenx build)"
echo "==================================================="

if [ -x "$DEST/Contents/Resources/wine/bin/wine" ]; then
  echo "✅ Wine Staging is already installed at:"
  echo "   $DEST"
  echo "You can close this window and reopen SAI Pen Pressure."
  exit 0
fi

URL="${WINE_URL:-}"
if [ -z "$URL" ]; then
  echo "Finding the latest Wine Staging build for macOS…"
  URL=$(curl -fsSL "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=30" \
        | grep -oiE 'https://[^"]+staging[^"]+osx64[^"]*\.tar\.xz' | head -1 || true)
fi
if [ -z "$URL" ]; then
  echo ""
  echo "Couldn't find a download automatically. Please install manually:"
  echo "  1. Open https://github.com/Gcenx/macOS_Wine_builds/releases"
  echo "  2. Download a 'wine-staging-…-osx64.tar.xz'"
  echo "  3. Extract it and put 'Wine Staging.app' in /Applications"
  exit 1
fi

echo ""
echo "Downloading (~300 MB — this can take a few minutes):"
echo "  $URL"
echo ""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -L --progress-bar "$URL" -o "$TMP/wine.tar.xz"

echo ""
echo "Extracting…"
tar -xf "$TMP/wine.tar.xz" -C "$TMP"
APP="$(find "$TMP" -maxdepth 3 -name '*.app' -type d | head -1 || true)"
if [ -z "$APP" ]; then echo "ERROR: no .app found inside the download."; exit 1; fi

echo "Installing to $DEST …"
rm -rf "$DEST"
mv "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true   # avoid Gatekeeper blocking it

echo ""
echo "✅ Done! Wine Staging is installed."
echo "   Now reopen 'SAI Pen Pressure' — it will find Wine and continue."

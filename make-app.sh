#!/bin/bash
# Assemble "SAI Pen Pressure.app" — a double-clickable macOS wrapper that sets
# up the Wine prefix (asking for your SAI folder on first run) and launches SAI
# + the pressure engine together. Output: ./dist/SAI Pen Pressure.app
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
APP="$REPO/dist/SAI Pen Pressure.app"
BUNDLE_ID="com.runasharp.saipenpressure"
# One source of truth for the version: the latest git tag (v0.1.0 -> 0.1.0).
# Override with SAIPP_VERSION; falls back to 0.0.0-dev outside a tagged repo.
VERSION="${SAIPP_VERSION:-$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0-dev}"
echo "Version: $VERSION"

echo "Building helper (with --app support)..."
( cd "$REPO/wacom-helper" && swiftc -O -o wacom-pressure-helper main.swift PressureCore.swift )

echo "Assembling bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The main executable must be a REAL Mach-O binary (a shell-script launcher makes
# downloaded/quarantined apps fail to open with error -47). So the compiled
# helper IS the main executable; it auto-detects app mode from being in a .app.
cp "$REPO/wacom-helper/wacom-pressure-helper" "$APP/Contents/MacOS/SAIPenPressure"
chmod +x "$APP/Contents/MacOS/SAIPenPressure"

# our DLL + the Wine installer live in Resources
cp "$REPO/wintab-src/wintab32.dll"  "$APP/Contents/Resources/wintab32.dll"
cp "$REPO/install-wine.sh"          "$APP/Contents/Resources/install-wine.sh"
chmod +x "$APP/Contents/Resources/install-wine.sh"

# App icon — render the pen emoji to a 1024px PNG, then build an .icns.
# Best-effort: if anything fails the app just uses the default icon (non-fatal).
HAS_ICON=""
ICONWORK="$(mktemp -d)"
if swiftc -O -o "$ICONWORK/make-icon" "$REPO/make-icon.swift" 2>/dev/null \
   && "$ICONWORK/make-icon" "$ICONWORK/icon1024.png" 2>/dev/null; then
  mkdir -p "$ICONWORK/icon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s        "$ICONWORK/icon1024.png" --out "$ICONWORK/icon.iconset/icon_${s}x${s}.png"    >/dev/null 2>&1
    sips -z $((s*2)) $((s*2)) "$ICONWORK/icon1024.png" --out "$ICONWORK/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  if iconutil -c icns "$ICONWORK/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    HAS_ICON=1
    echo "App icon: built AppIcon.icns from pen emoji."
  fi
fi
[ -z "$HAS_ICON" ] && echo "App icon: skipped (using default) — non-fatal."
rm -rf "$ICONWORK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SAI Pen Pressure</string>
  <key>CFBundleDisplayName</key><string>SAI Pen Pressure</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>SAIPenPressure</string>${HAS_ICON:+
  <key>CFBundleIconFile</key><string>AppIcon</string>}
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- shown in the permission prompts -->
  <key>NSInputMonitoringUsageDescription</key>
  <string>Reads pen pressure from your drawing tablet to send it to SAI.</string>
</dict>
</plist>
PLIST

# --- Code signing -----------------------------------------------------------
# Default: AD-HOC. Ad-hoc gives every build its own distinct identity, so macOS
# treats each rebuild as a separate app. That's what we want while developing:
# the Mac app's permissions/state stay INDEPENDENT and don't get entangled with
# other builds (a stable identity persists TCC grants across rebuilds, but that
# also connects the versions and gets in the way of debugging).
# To opt into a stable identity on purpose, pass SIGN_ID="<identity name or hash>".
if [ -n "$SIGN_ID" ]; then
  echo "Signing with identity: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "Signed ad-hoc (each build independent)."
fi

echo ""
echo "Built: $APP"
echo "First launch: right-click the app → Open (unsigned-developer bypass, once)."
echo "The setup window walks through Wine / SAI folder / permissions."

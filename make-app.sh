#!/bin/bash
# Assemble "SAI Pen Pressure.app" — a double-clickable macOS wrapper that sets
# up the Wine prefix (asking for your SAI folder on first run) and launches SAI
# + the pressure engine together. Output: ./dist/SAI Pen Pressure.app
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
APP="$REPO/dist/SAI Pen Pressure.app"
BUNDLE_ID="com.runasharp.saipenpressure"

echo "Building helper (with --app support)..."
( cd "$REPO/wacom-helper" && swiftc -O -o wacom-pressure-helper main.swift )

echo "Assembling bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# main executable is a tiny launcher that runs the helper with --app
cat > "$APP/Contents/MacOS/SAI Pen Pressure" <<'LAUNCH'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/wacom-pressure-helper" --app
LAUNCH
chmod +x "$APP/Contents/MacOS/SAI Pen Pressure"

# the real binary + our DLL + the Wine installer live inside the bundle
cp "$REPO/wacom-helper/wacom-pressure-helper" "$APP/Contents/MacOS/wacom-pressure-helper"
cp "$REPO/wintab-src/wintab32.dll"            "$APP/Contents/Resources/wintab32.dll"
cp "$REPO/install-wine.sh"                    "$APP/Contents/Resources/install-wine.sh"
chmod +x "$APP/Contents/Resources/install-wine.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SAI Pen Pressure</string>
  <key>CFBundleDisplayName</key><string>SAI Pen Pressure</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>SAI Pen Pressure</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- shown in the permission prompts -->
  <key>NSInputMonitoringUsageDescription</key>
  <string>Reads pen pressure from your drawing tablet to send it to SAI.</string>
</dict>
</plist>
PLIST

# ad-hoc code signature so macOS keeps the permission grant stable across runs
# Sign with a STABLE self-signed identity if one exists, so macOS keeps the
# Input Monitoring / Accessibility grants across rebuilds. Falls back to ad-hoc
# (which changes each build -> you must re-grant permissions after every rebuild).
SIGN_ID="${SIGN_ID:-SAI Pen Pressure Local}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "Signing with stable identity: \"$SIGN_ID\" (permissions persist across rebuilds)"
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "NOTE: signed ad-hoc — you'll have to RE-GRANT permissions after each rebuild."
  echo "      To make grants persist: Keychain Access -> Certificate Assistant ->"
  echo "      Create a Certificate named \"$SIGN_ID\", type 'Code Signing', self-signed."
fi

echo ""
echo "Built: $APP"
echo "First launch: right-click the app → Open (unsigned-developer bypass, once)."
echo "The setup window walks through Wine / SAI folder / permissions."

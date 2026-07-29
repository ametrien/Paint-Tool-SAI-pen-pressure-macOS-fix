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

# Universal (arm64 + x86_64) so the release runs natively on Apple Silicon AND
# on Intel Macs (#6). Both slices are cross-compiled from whichever machine
# builds; no Intel hardware needed. The x86_64 slice can even be exercised on
# Apple Silicon with `arch -x86_64`, via Rosetta.
# UNIVERSAL=0 builds only the host architecture (faster while iterating).
echo "Building helper (with --app support)..."
if [ "${UNIVERSAL:-1}" = "1" ]; then
  ( cd "$REPO/wacom-helper" \
    && swiftc -O -target x86_64-apple-macos12.0 -o .helper-x86 main.swift PressureCore.swift LibraryStore.swift LibraryUI.swift ../timelapse-encoder/LibraryCore.swift \
    && swiftc -O -target arm64-apple-macos12.0  -o .helper-arm main.swift PressureCore.swift LibraryStore.swift LibraryUI.swift ../timelapse-encoder/LibraryCore.swift \
    && lipo -create -output wacom-pressure-helper .helper-x86 .helper-arm \
    && rm -f .helper-x86 .helper-arm )
  echo "  architectures: $(lipo -archs "$REPO/wacom-helper/wacom-pressure-helper")"
else
  ( cd "$REPO/wacom-helper" && swiftc -O -o wacom-pressure-helper main.swift PressureCore.swift LibraryStore.swift LibraryUI.swift ../timelapse-encoder/LibraryCore.swift )
  echo "  host architecture only (UNIVERSAL=0)"
fi

# The timelapse encoder is a SEPARATE binary, not part of the helper. The
# helper's job is realtime pen input; an encoder doing video work and disk I/O
# in the same process invites jitter on exactly the path this project exists to
# protect. It is also far easier to test standalone against a folder of frames.
echo "Building timelapse encoder..."
if [ "${UNIVERSAL:-1}" = "1" ]; then
  ( cd "$REPO/timelapse-encoder" \
    && swiftc -O -target x86_64-apple-macos12.0 -o .enc-x86 EncoderCore.swift LibraryCore.swift main.swift \
    && swiftc -O -target arm64-apple-macos12.0  -o .enc-arm EncoderCore.swift LibraryCore.swift main.swift \
    && lipo -create -output sai-timelapse-encoder .enc-x86 .enc-arm \
    && rm -f .enc-x86 .enc-arm )
else
  ( cd "$REPO/timelapse-encoder" \
    && swiftc -O -o sai-timelapse-encoder EncoderCore.swift LibraryCore.swift main.swift )
fi

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
# Ships inside the bundle so it is signed with the app and needs no separate
# Gatekeeper approval. Lives in Resources rather than MacOS: it is a tool the
# app invokes, not a second launchable app.
cp "$REPO/timelapse-encoder/sai-timelapse-encoder" "$APP/Contents/Resources/sai-timelapse-encoder"
chmod +x "$APP/Contents/Resources/sai-timelapse-encoder"

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
# Prefer a REAL signing identity when the machine has one; fall back to ad-hoc.
#
# This used to default to ad-hoc on purpose, reasoning that a distinct identity
# per build keeps permissions from entangling across versions. In practice that
# was backwards: TCC attaches Input Monitoring to a code identity, and an ad-hoc
# signature has no Team ID and a fresh hash every build — so macOS has nothing
# durable to grant to. Every rebuild lost the permission, the list filled with
# duplicate "SAI Pen Pressure" entries, and the system never showed a prompt at
# all. Signing once means granting once.
#
#   SIGN_ID="<name or hash>"   use a specific identity
#   SIGN_ID="-"                force ad-hoc (what CI gets anyway — no certs there)
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
             | awk -F'"' '/^ *[0-9]+\)/ { print $2; exit }')"
  [ -n "$SIGN_ID" ] && echo "Found a signing identity; using it (SIGN_ID=- forces ad-hoc)."
fi
if [ -n "${SIGN_ID:-}" ] && [ "$SIGN_ID" != "-" ]; then
  echo "Signing with identity: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "Signed ad-hoc — macOS will NOT prompt for Input Monitoring; add the app by hand."
fi

echo ""
echo "Built: $APP"
echo "First launch: right-click the app → Open (unsigned-developer bypass, once)."
echo "The setup window walks through Wine / SAI folder / permissions."

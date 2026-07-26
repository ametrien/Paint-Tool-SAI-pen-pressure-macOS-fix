#!/bin/bash
# install.sh — set up SAI Ver.2 on macOS with pen pressure.
#
# Automates the mechanical parts: creates a Wine prefix, copies SAI into it,
# installs the custom wintab32.dll + override, installs your licence, and
# generates a one-click launcher. You still do the manual steps the installer
# can't (install Wine, download SAI, grant permissions, enable "Use WinTab
# API") — it prints those at the end.
#
# WHAT LIVES WHERE (this trips people up):
#   your SAI folder      -> a SOURCE. Copied once; not needed to run.
#   $PREFIX/drive_c/SAI2 -> what actually RUNS, licence included.
#   $SUPPORT/bin         -> the pressure helper, copied out of this repo so the
#                           launcher keeps working if you move or delete it.
#
# Usage:
#   ./install.sh                     full setup (asks for your SAI folder)
#   ./install.sh --install-license   just install a .slc into the prefix
#   ./install.sh --repair            re-copy SAI + the bridge, keep the prefix
#   ./install.sh --rebuild           delete the prefix and build it from scratch
#   ./install.sh --help
#
# Override any path via env, e.g.:
#   SAI_PREFIX=~/mysai  SAI2_SRC=~/Downloads/sai2-...  ./install.sh
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${SAI_PREFIX:-$HOME/SAI2-pressure}"
WINE="${WINE:-/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine}"
DLL="$REPO/wintab-src/wintab32.dll"
HELPER_SRC="$REPO/wacom-helper/wacom-pressure-helper"
SUPPORT="$HOME/Library/Application Support/SAIPenPressure"
HELPER="$SUPPORT/bin/wacom-pressure-helper"
PRESSURE_FILE="$PREFIX/drive_c/wt_pressure.txt"
PREFIX_SAI="$PREFIX/drive_c/SAI2"

# --- path normalisation ------------------------------------------------------
# `read` hands us the line LITERALLY — it is never evaluated by a shell. People
# paste quoted paths (natural, since SAI folders often contain a space) and
# Finder drag-and-drop appends a trailing space, so both used to fail with a
# confusing "sai2.exe not found in: '/Users/...'". Strip that here.
normalize_path() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"          # leading whitespace
  p="${p%"${p##*[![:space:]]}"}"          # trailing whitespace
  case "$p" in                             # one matching pair of surrounding quotes
    \'*\') p="${p#\'}"; p="${p%\'}" ;;
    \"*\") p="${p#\"}"; p="${p%\"}" ;;
  esac
  p="${p%/}"                               # trailing slash
  printf '%s' "${p/#\~/$HOME}"             # ~ expansion
}

# --- licence install (shared by the CLI flag and the full install) -----------
# NOTE: this project does NOT supply, generate or activate licences and has no
# affiliation with SYSTEMAX. It only copies a .slc the user already bought into
# the folder SAI actually reads.
install_license() {
  local picked="${1:-}"
  if [ -z "$picked" ]; then
    echo ""
    echo "  You need your OWN SAI license certificate (.slc)."
    echo "  PaintTool SAI is commercial software by SYSTEMAX. Buy a license and"
    echo "  download your .slc from the official site:"
    echo "      https://www.systemax.jp/en/sai/"
    echo "  This project is NOT affiliated with SYSTEMAX and cannot provide,"
    echo "  generate or activate a license — it only copies yours into place."
    echo ""
    picked=$(osascript -e 'POSIX path of (choose file with prompt "Select YOUR OWN SAI license certificate (.slc)")' 2>/dev/null || true)
  fi
  picked="$(normalize_path "$picked")"
  if [ -z "$picked" ]; then echo "No license selected — skipping."; return 1; fi
  case "$picked" in
    *.slc|*.SLC) : ;;
    *) echo "ERROR: not a .slc certificate: $picked"; return 1 ;;
  esac
  if [ ! -f "$picked" ]; then echo "ERROR: no such file: $picked"; return 1; fi
  # Where SAI reads the certificate changed between builds: older Ver.2 builds
  # look next to sai2.exe, the 2026-07-12 "Major Renovated" preview looks in a
  # `settings` folder. Guessing wrong is indistinguishable from an invalid
  # licence — SAI just won't save. It's 128 bytes; write both.
  mkdir -p "$PREFIX_SAI" "$PREFIX_SAI/settings" "$SUPPORT/license"
  cp "$picked" "$PREFIX_SAI/"
  cp "$picked" "$PREFIX_SAI/settings/"
  cp "$picked" "$SUPPORT/license/"          # so --rebuild can put it back
  echo "License installed (both locations, for old and new SAI builds):"
  echo "  $PREFIX_SAI/$(basename "$picked")"
  echo "  $PREFIX_SAI/settings/$(basename "$picked")"
  echo "Quit SAI completely and relaunch for it to take effect."
}

restore_licenses() {
  [ -d "$SUPPORT/license" ] || return 0
  shopt -s nullglob
  local f found=0
  for f in "$SUPPORT/license"/*.slc "$SUPPORT/license"/*.SLC; do
    mkdir -p "$PREFIX_SAI" "$PREFIX_SAI/settings"      # old + new build locations
    [ -e "$PREFIX_SAI/$(basename "$f")" ]          || cp "$f" "$PREFIX_SAI/"
    [ -e "$PREFIX_SAI/settings/$(basename "$f")" ] || cp "$f" "$PREFIX_SAI/settings/"
    found=1
  done
  shopt -u nullglob
  [ "$found" = 1 ] && echo "Restored saved license into the prefix."
  return 0
}

# --- args --------------------------------------------------------------------
MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --install-license) MODE="license" ;;
    --repair)          MODE="repair" ;;
    --rebuild)         MODE="rebuild" ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
  shift
done

if [ "$MODE" = "license" ]; then
  install_license
  exit $?
fi

echo "== SAI pen-pressure installer =="
echo "  prefix : $PREFIX"
echo "  wine   : $WINE"
[ "$MODE" != "install" ] && echo "  mode   : $MODE"

# --- prerequisites ----------------------------------------------------------
if [ ! -x "$WINE" ]; then
  echo "ERROR: Wine not found at:"
  echo "  $WINE"
  echo "Install Gcenx 'Wine Staging' (https://github.com/Gcenx/macOS_Wine_builds/releases)"
  echo "and put 'Wine Staging.app' in /Applications, or set WINE=/path/to/wine."
  exit 1
fi
if [ ! -f "$DLL" ]; then
  echo "ERROR: prebuilt wintab32.dll not found at $DLL"
  echo "Build it first (see README 'Build from source')."
  exit 1
fi
if [ ! -x "$HELPER_SRC" ]; then
  echo "Note: helper binary not found; attempting to build it..."
  ( cd "$REPO/wacom-helper" && swiftc -O -o wacom-pressure-helper main.swift PressureCore.swift ) \
    || { echo "ERROR: could not build the helper (needs Xcode command-line tools)."; exit 1; }
fi

# --- locate SAI2 ------------------------------------------------------------
# --repair/--rebuild reuse the folder recorded by a previous run, so you don't
# have to remember and retype it.
if [ -z "${SAI2_SRC:-}" ] && [ -f "$SUPPORT/config.txt" ]; then
  SAI2_SRC="$(cat "$SUPPORT/config.txt")"
  [ -n "$SAI2_SRC" ] && echo "  source : $SAI2_SRC  (remembered)"
fi
if [ -z "${SAI2_SRC:-}" ]; then
  echo ""
  echo "Enter the path to your extracted SAI2 folder (the one containing sai2.exe)."
  echo "No quotes needed — spaces are fine. You can also drag the folder in."
  read -r SAI2_SRC
fi
SAI2_SRC="$(normalize_path "$SAI2_SRC")"
if [ ! -f "$SAI2_SRC/sai2.exe" ]; then
  echo "ERROR: sai2.exe not found in: $SAI2_SRC"
  echo ""
  echo "Pick the folder that DIRECTLY contains sai2.exe."
  echo "If the path has spaces, type it WITHOUT quotes, or run non-interactively:"
  echo "  SAI2_SRC=\"/path/to/SAI 2\" ./install.sh"
  exit 1
fi

# --- create the prefix ------------------------------------------------------
export WINEPREFIX="$PREFIX"
export WINEDEBUG=-all
if [ "$MODE" = "rebuild" ]; then
  # Save any licence sitting in the prefix before it goes.
  if [ -d "$PREFIX_SAI" ]; then
    mkdir -p "$SUPPORT/license"
    shopt -s nullglob
    for f in "$PREFIX_SAI"/*.slc "$PREFIX_SAI"/*.SLC; do cp "$f" "$SUPPORT/license/"; done
    shopt -u nullglob
  fi
  echo "Deleting the prefix for a full rebuild: $PREFIX"
  rm -rf "$PREFIX"
fi
if [ ! -d "$PREFIX/drive_c" ]; then
  echo "Creating Wine prefix (first run downloads/initialises; may take a minute)..."
  "$WINE" wineboot -i >/dev/null 2>&1 || true
  "$WINE" wineboot -u >/dev/null 2>&1 || true
fi

# --- install SAI ------------------------------------------------------------
echo "Installing SAI into the prefix..."
# On repair/rebuild clear the destination first so files removed from the source
# don't linger and a half-broken install can't survive the "reinstall".
if [ "$MODE" != "install" ] && [ -d "$PREFIX_SAI" ]; then
  mkdir -p "$SUPPORT/license"
  shopt -s nullglob
  for f in "$PREFIX_SAI"/*.slc "$PREFIX_SAI"/*.SLC; do cp "$f" "$SUPPORT/license/"; done
  shopt -u nullglob
  rm -rf "$PREFIX_SAI"
fi
mkdir -p "$PREFIX_SAI"
cp -R "$SAI2_SRC/." "$PREFIX_SAI/"

# --- install the pressure bridge -------------------------------------------
echo "Installing wintab32.dll + override..."
mkdir -p "$PREFIX/drive_c/windows/system32"
cp "$DLL" "$PREFIX/drive_c/windows/system32/wintab32.dll"
"$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v wintab32 /t REG_SZ /d "native,builtin" /f >/dev/null 2>&1
# Mac-friendly shortcuts: let Wine map Command -> Control inside Wine apps
# (undo/redo/save/etc.). Driver-level, no Accessibility permission needed.
"$WINE" reg add "HKCU\\Software\\Wine\\Mac Driver" /v LeftCommandIsCtrl  /t REG_SZ /d Y /f >/dev/null 2>&1
"$WINE" reg add "HKCU\\Software\\Wine\\Mac Driver" /v RightCommandIsCtrl /t REG_SZ /d Y /f >/dev/null 2>&1
echo 0 > "$PRESSURE_FILE"

restore_licenses

# --- install the helper OUT of the repo -------------------------------------
# The launcher used to point straight at $REPO/wacom-helper/..., which made this
# working copy a permanent runtime dependency — move or delete the repo and the
# launcher broke, even though the real install lives entirely in the prefix.
mkdir -p "$SUPPORT/bin"
cp "$HELPER_SRC" "$HELPER"
chmod +x "$HELPER"

# Record the source folder so the setup app and --repair agree with this run.
mkdir -p "$SUPPORT"
printf '%s' "$SAI2_SRC" > "$SUPPORT/config.txt"
printf '%s' "$SAI2_SRC" > "$SUPPORT/installed-src.txt"

# --- generate a personal one-click launcher ---------------------------------
LAUNCHER="$REPO/Start SAI2 (my setup).command"
cat > "$LAUNCHER" <<EOF
#!/bin/bash
# Auto-generated by install.sh for this machine.
#
# This is the COMMAND-LINE launcher: pressure only. It does NOT provide the
# menu-bar pen icon, "Wake SAI" (⌃⌥⌘Space), auto-wake, the setup window or the
# update check — those live in the SAI Pen Pressure app (./make-app.sh).
# It reads nothing from the repo, so you can move this file anywhere.
export WINEPREFIX="$PREFIX"
export WINEDEBUG=-all
export WT_PRESSURE_FILE="$PRESSURE_FILE"
HELPER="$HELPER"
WINE="$WINE"

echo 0 > "\$WT_PRESSURE_FILE"
"\$HELPER" > "$PREFIX/helper.log" 2>&1 &
HP=\$!
trap 'echo 0 > "\$WT_PRESSURE_FILE" 2>/dev/null; kill \$HP 2>/dev/null' EXIT INT TERM
rm -f "$PREFIX/drive_c/wtlog.txt"
echo "Pen pressure active. Close SAI to stop."
cd "$PREFIX_SAI"
"\$WINE" sai2.exe
EOF
chmod +x "$LAUNCHER"

# --- licence ----------------------------------------------------------------
if ls "$PREFIX_SAI"/*.slc >/dev/null 2>&1; then
  echo "License already in the prefix: $(basename "$(ls "$PREFIX_SAI"/*.slc | head -1)")"
else
  echo ""
  echo "No license (.slc) in the prefix yet — SAI can draw but not save."
  echo "Licenses come from SYSTEMAX (https://www.systemax.jp/en/sai/), not from"
  echo "this project. If you already own one, we can copy it into place now."
  printf "Install your .slc now? [y/N] "
  read -r ans
  case "$ans" in [yY]*) install_license || true ;; esac
fi

# --- done -------------------------------------------------------------------
cat <<EOF

== Installed ==

SAI now lives in:  $PREFIX_SAI
(copied from:      $SAI2_SRC — only needed again for a reinstall)

RECOMMENDED: build and use the app instead of the .command launcher —
it adds the menu-bar pen icon, Wake SAI, auto-wake and the setup window:
   ./make-app.sh   then open "dist/SAI Pen Pressure.app"

Remaining MANUAL steps

1. Permission: System Settings -> Privacy & Security -> grant your terminal
   (or the app) 'Input Monitoring', then restart it. That's the only one —
   Cmd->Ctrl shortcuts are handled by Wine.

2. In SAI: Others -> Options -> Pen Tablet -> 'Use WinTab API', restart SAI.

Command-line launcher (pressure only):
   $LAUNCHER

Other commands:
   ./install.sh --install-license    install a .slc certificate
   ./install.sh --repair             re-copy SAI + bridge, keep the prefix
   ./install.sh --rebuild            delete the prefix and start clean

Kill switch if needed:  echo 0 > "$PRESSURE_FILE"
EOF

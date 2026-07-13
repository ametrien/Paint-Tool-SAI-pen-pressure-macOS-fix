# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/), versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Wake SAI** — one-key recovery for the Wine app-switch freeze: **⌃⌥Space** (global
  hotkey), a **🖊 menu-bar item**, and a setup-window button. Finds the exact process
  that owns SAI's on-screen window (via `CGWindowList`) and hides+re-activates it — the
  programmatic equivalent of the manual Space-swipe. No new permission. Also auto-wakes
  SAI when you return to it via Cmd-Tab.
- **KNOWN_ISSUES.md** documenting the pen-vs-menu and Wine focus quirks in full —
  cause, what we tried, what didn't work, and the workaround for each.
- `WT_NO_HOVER=1` diagnostic env flag on the helper (streams presses only, no hover)
  to investigate SAI's pen-vs-mouse suppression.
- **Test Tablet Pressure** button in the setup window: a live 0–100% bar
  (custom-drawn, no easing — tracks the raw pen exactly) to confirm the tablet
  works *before* launching SAI. Doubles as a real Input Monitoring check.
- **Uninstall Wine** option in the setup window (moves `Wine Staging.app` to
  the Trash; your SAI setup and license are kept).
- App icon (pen emoji, generated at build time by `make-icon.swift`).
- `--version` flag on the helper binary (useful in bug reports).
- **Unit tests** for the pure pressure-pipeline logic (`tests/run-tests.sh`):
  coordinate mapping, packet conflation, sample parsing, dedup/keepalive rules,
  Cmd→Ctrl remap decisions, multi-monitor union — run natively, no hardware.
- Release automation: pushing a `v*` tag builds, zips, and attaches the app to
  a GitHub Release.

### Changed
- **Cmd→Ctrl shortcuts now handled by Wine** (`LeftCommandIsCtrl` registry key),
  not a CGEventTap in the helper. This fixes the remap producing wrong shortcuts
  (#7) **and removes the Accessibility permission entirely** — the app now needs
  only Input Monitoring. The installer/app set the key automatically on launch.
  Closes #5, #7. (The old event-tap remap + `shouldRemapKey` logic were removed.)
- Setup wizard now has a single permission row (**Input Monitoring**); the
  optional Accessibility row is gone.
- Specific, actionable error messages when the chosen SAI folder is missing,
  has no `sai2.exe`, or the copy into the Wine prefix fails.
- Pure logic extracted into `wacom-helper/PressureCore.swift` and
  `wintab-src/wintab_core.h` (OS glue unchanged) so it can be unit-tested.
- App builds are ad-hoc signed (each build independent); the compiled helper
  binary is no longer committed — it's built from source automatically.
- App version now derives from the git tag instead of a hardcoded value.

## [0.1.0] — 2026-07-10

### Added
- First release: real Wacom **pen pressure for PaintTool SAI Ver.2 under Wine
  on macOS** via a custom `wintab32.dll` + native macOS helper.
- Pressure, hover cursor tracking, mouse/trackpad coexistence, multi-monitor
  support, Mac-style **Cmd→Ctrl** shortcut remapping while SAI is frontmost.
- Double-clickable **SAI Pen Pressure.app** with a step-by-step setup window
  (Wine install, SAI folder pick, permission checks) — no terminal needed.
- Automatic Wine installation (Gcenx Wine Staging) with visible progress.
- Manual command-line route (`install.sh`) for developers.

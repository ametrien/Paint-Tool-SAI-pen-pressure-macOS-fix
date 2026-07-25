# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/), versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.5] — 2026-07-25

### Fixed
- **The app-switch freeze auto-recovers — for real this time** (#2). Live-debugging a stuck
  SAI showed *three* stacked breakages, and the wake now repairs all of them from inside
  SAI's process, on its UI thread (marshalled via a thread-scoped `WH_GETMESSAGE` hook):
  1. wineserver **foreground** parked on the desktop window, with Wine's foreground lock
     refusing `SetForegroundWindow` from a non-foreground process (`AttachThreadInput`
     bypass, then retry);
  2. the **Mac key window** — `winemac.drv` only informs macOS on a focus *change*, so the
     wake toggles focus through NULL to force the driver call;
  3. **SAI's own "am I active" flag** — set only by `WM_ACTIVATE`/`WM_ACTIVATEAPP`
     *messages*, which Wine never sends when it restores state without a change; the wake
     synthesizes the real activation message sequence. This was the decisive layer.
  Triggered automatically on returning to SAI (plus a second wake ~0.6 s after the
  transition settles), on dead-canvas clicks, and manually via ⌃⌥⌘Space / 🖊 / the setup
  window. Wake attempts always log to `C:\wt_wakelog.txt` and `/tmp/sai-wake.log`.
  Opt out: `WT_NO_WIN32_WAKE=1`.
- **Single pen tap on a brush slot no longer opens the double-click Property dialog** (#8).
  The tablet can report one physical touch as two (pressure dips through zero and back —
  field log: re-touch at the same spot 72 ms later). A **pen-up latch** holds each pen-up
  for 150 ms (`WT_UP_LATCH=<ms>`, 0 disables) and absorbs same-spot re-touches; human
  double-taps still pass. Plus a safety net: the DLL eats Wine's synthesized left-clicks
  arriving within 400 ms of a real pen-tip transition (main window client area only —
  dialogs and the menu bar untouched; `WT_NO_CLICK_DEDUP=1` disables).
- **No cursor lag after strokes**: the latch releases hover tracking the moment the pen
  moves past the absorb radius, so the brush cursor chases the pen immediately.
- **Setup window**: the "Update available" line no longer overflows — the release-notes
  teaser moved into a tooltip and the label truncates gracefully.

## [0.1.4] — 2026-07-25

### Added
- **Pen taps now work on SAI's top menu row** (File/Edit/Canvas/…) — fixes #1. While the pen
  is over SAI's menu strip the helper streams nothing, so SAI takes the pen's plain mouse
  click and the menu opens. Canvas/pressure unchanged. Tune with `WT_MENU_STRIP=<points>`.
- **Version + update check** in the setup window — shows the current version and, on launch,
  whether a newer GitHub release exists, with a "What's new / Update…" link to the notes.
- **Auto-wake when returning to SAI** (experimental, toggle in the 🖊 menu) — re-activates the
  correct Wine window-owner process on app-switch return. Helps but doesn't fully solve the
  freeze (#2, still open); the manual Wake remains the reliable recovery.

### Known / unresolved
- **App-switch freeze (#2)** is now root-caused (SAI loses Win32 foreground → canvas dead to
  pen *and* mouse; Wacom demotes the pen to a plain mouse) but only has a **manual** recovery
  (⌃⌥⌘Space / 🖊 Wake). Full auto-recovery is still open — details in KNOWN_ISSUES / issue #2.

### Added (earlier)
- **Wake SAI** — one-key recovery for the Wine app-switch freeze: **⌃⌥⌘Space** (global
  hotkey), a **🖊 menu-bar item**, and a setup-window button. Finds the exact process
  that owns SAI's on-screen window (via `CGWindowList`) and re-activates it — no hide, so
  the pen state isn't disturbed (`WT_WAKE_HIDE=1` forces a heavier hide+reactivate). The
  hotkey is read by the same listen-only tap that reads the tablet (Carbon's global-hotkey
  API didn't deliver, and ⌃⌥Space collides with macOS "next input source"). No new
  permission. Also auto-wakes SAI on Cmd-Tab return.
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

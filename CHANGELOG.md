# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/), versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **A drawing made over several evenings becomes one video.** Reopen a picture tomorrow and tonight's
  recording is added to it, instead of leaving you with a folder of disconnected clips named after
  dates. Each session is still kept as its own file, and the combined video is rebuilt from them —
  so nothing that already exists is ever rewritten, and a failure can only cost the session that
  failed.
- **The app recognises a drawing by what it looks like**, not by its name. Rename the canvas, move
  the file, Save As — it still knows. Inside one session a canvas is identified by its address in
  SAI's memory, which means nothing once SAI has quit; comparing the picture is what survives.
- **It asks when it isn't sure.** A session that has moved on a long way since you last drew is
  plausible rather than certain, so it becomes its own drawing and asks — with the two pictures side
  by side — instead of merging quietly. Saying no is remembered. Ignoring the question is fine: the
  video already exists either way.
- **Hover a still to play it.** A timelapse is motion, and the last frame of two drawings can look
  much alike — pointing at one plays it in place, without opening anything.
- **A Videos tab** listing your drawings, with a still from each, and buttons to play, rebuild,
  export or take a session out of the drawing it was put in.

### Changed
- **Video length is chosen when you export**, not while recording. Your drawing keeps its full-length
  video and the cap makes a separate copy, so asking for 30 seconds twice never compounds.
- Recording now happens in a hidden staging folder, so the videos folder holds only finished work.
- Videos already in the folder — including everything recorded before this update — are listed
  rather than ignored, with Play, Show in Finder and Delete.
- The two tabs are now **Recording** (what happens while you draw) and **Videos** (what came out).
- Changing the videos folder updates the list straight away, and each folder keeps its own index —
  so a folder moved to another Mac still knows which sessions belong to which drawing.

## [0.2.2] — 2026-07-28

### Fixed
- **Making a video no longer stops the recording.** "Make video…" has to pause the encoder to
  finish the video off, but it never started it again — so you got one video per SAI session, and
  the only way to record more was to quit SAI and relaunch. Nothing about the button implied that,
  which is why it went unnoticed: it did what it said, and quietly did something else too.
- **The Recording tab updates while you watch it.** It showed whatever it said when you switched to
  it, so drawing for ten minutes still read "Nothing recorded yet".
- **Recording survives restarting the app.** The encoder only ever started when the app launched
  SAI, so reopening the app while SAI was already running left the rest of that session unrecorded,
  silently. It now starts whenever recording is on and SAI is up, and restarts if it stops.
- **Each recording gets its own filename.** Every session wrote to `SAI Timelapse.mp4`, so making a
  second video — or simply drawing again the next day — replaced the previous one without asking.
  Sessions are timestamped now.
- **Recordings are no longer stranded by an app update.** Counting and finishing were tied to the
  current session's name, so a recording made before an update became invisible: still on disk, no
  way to turn it into a video.

## [0.2.1] — 2026-07-28

### Changed
- **The timelapse is encoded while you draw**, instead of raw frames piling up until you ask for a
  video. Frames are turned into video within about a second of being captured and then deleted, so
  disk use stays flat rather than growing with the session. Measured on a 1000×700 canvas: 51 frames
  is 143 MB raw and 0.10 MB encoded — around 1400× on sparse line art, less on a dense painting, but
  the difference between megabytes and gigabytes either way. The 2 GB frame budget is now a fallback
  for an encoder that has fallen behind rather than the main defence.
- **Make video is near-instant.** Most of the work has already happened, so it stitches the encoded
  segments together instead of encoding everything from scratch. A requested length is applied by
  re-timing rather than dropping frames, which is the right tool once the frames are already video.

### Fixed
- **`--watch` destroyed everything it had already encoded.** It opened a fresh writer on every poll,
  and a new `AVAssetWriter` truncates its output file, so each pass replaced the video with only the
  newest frames — and since frames are deleted once consumed, the earlier footage was gone. Measured
  before the fix: 3 frames encoded, 6 more arrive, final video contains 6 rather than 9. Nothing in
  the app called it in 0.2.0, but it was a documented flag.

## [0.2.0] — 2026-07-28

### Added
- **Canvas timelapse recording.** Records your drawing as a video, one frame per finished brush
  stroke, so hours collapse into a couple of minutes. It reads SAI's canvas out of memory rather
  than capturing the screen, so the video shows the flat canvas only — no panels, no cursor, and no
  camera movement when you zoom, pan or rotate while working. Layer opacity, blend modes and undo
  all appear, because what is recorded is the composited canvas. On by default; the Recording tab
  has the switch.
  - **Several open canvases are recorded separately**, one video each. Tracked by identity rather
    than by name, so renaming a canvas mid-session relabels its video instead of splitting it in two.
  - **Video length is a duration, not a frame rate.** Frames are captured per stroke, so asking for
    "1 minute" drops frames evenly to hit it. "Everything" is the default — silently discarding
    somebody's first recording is the wrong thing to do by default.
  - **Frames are bounded.** They are raw and about 3 MB each, so past 2 GB every second frame is
    dropped: that halves the size while still spanning the whole session, which is better than
    losing the beginning. Frames are deleted as they are encoded.
  - Videos are built by a small bundled encoder using AVFoundation — nothing to install.
- **Update SAI…** on the Setup tab swaps in a newer SAI build without a full reinstall, keeping your
  licence, brushes, presets and preferences. SAI Ver.2 is a rolling preview, so this is routine
  rather than a repair; the old path rebooted the Wine prefix and cleared the SAI folder for no
  reason.
- **A scratch pad in the pen test** would show taper directly rather than as a number. Written and
  working, but not shipped on the Pen tab in this release — it kept squeezing the settings out of
  the layout, and the settings matter more.

### Changed
- **The setup window is four tabs** — Setup, Pen, Recording, Developer. One column had grown taller
  than a screen, mixing install steps, pen settings and a log console.
- **The menu-bar and Dock menus are down to three items:** wake SAI, whether recording is on, and
  open the window. Everything else duplicated something in a tab.
- **Pressure levels say when no tablet is connected.** With nothing plugged in the row read "using
  the safe default 4096", but that number is usually remembered from the last tablet — describing
  stale data as a default hid both that fact and the more useful one.

### Fixed
- **The license in your SAI folder is adopted on every setup**, not only the first time you pick the
  folder. v0.1.12 added the adoption but hooked it to choosing a folder — something nobody does
  twice — so every existing install kept an empty backup copy and a rebuild would still have lost
  the certificate. The feature shipped without reaching the people it was written for.
- **Rebuilding the Wine prefix rescues a certificate that lives only in the prefix.** The rebuild
  deletes the prefix one level above where the existing "keep any certificate" step looks, so that
  step could never protect it.

## [0.1.12] — 2026-07-27

### Added
- **Setup shows what it's doing.** Reinstalling set one line of text and then went silent for about a
  minute while the Wine environment was prepared and SAI copied — no movement, so it read as a hang.
  Each step now names itself and drives the progress bar. The long step (`wineboot`) reports nothing
  a program can read, so the bar approaches that step's end without ever arriving: it always moves
  while work is happening, and never claims progress nobody observed. A step that runs longer than
  expected keeps creeping slowly rather than sitting at 100%.
- **A license already in your SAI folder is detected the moment you pick it** (#28). If a `.slc` is
  sitting there, it is taken under management immediately and you are told — rather than being asked
  to find a file you evidently already have. This also closes two quiet gaps: setup's plain copy left
  the certificate wherever it happened to sit in your folder, which may not be where the installed
  build reads from — and SAI's response to a certificate in the wrong folder is to silently refuse to
  save, indistinguishable from an invalid license. It also never reached the backup copy, so a rebuild
  lost it.

### Fixed
- **Wine is stopped before its prefix is rewritten or deleted** (#28). `wineserver` is a background
  process that outlives both SAI and this app, and nothing ever stopped it: uninstall removed the
  prefix while the daemon was still running against it, and reinstall rebuilt underneath it. A later
  launch could then inherit that stale process instead of starting cleanly.
- **Launching no longer starts a second SAI** if one is already open — it raises the existing window.
  Two instances share one Wine prefix and contend over the same settings and recovery files.

## [0.1.11] — 2026-07-27

### Fixed
- **The pen could not draw at all** (#26) — a regression introduced by 0.1.10's two-finger pan.
  Clicks were ignored inside parts of the SAI window while hover worked normally, and because a
  stroke that never starts also has no pressure, it presented as *"pen pressure stopped working"*.
  It survived reinstalls, so it looked like a broken install; it landed the same evening as a Mac
  restart, so it looked like a permissions problem. It was neither.
  Issue #19 had made the click de-dup opt-in with a guard at the **install site**: the message hook
  simply wasn't installed unless you asked for it, so the hook's existence implied consent and the
  hook procedure needed no check of its own. Two-finger pan (#24) needed that same hook, and pan is
  on by default — so the hook began installing for everyone, the install-site guard quietly stopped
  guarding anything, and `WM_LBUTTONDOWN` was eaten 2 ms after every pen-down again. The log said
  `dedup=off` the whole time, while the same log recorded it eating clicks.
  The decision now lives in `wintab_core.h` as `wtc_should_eat_click()`, gated on the resolved flag
  and covered by native tests — the Win32 version was unreachable from the test suite, which is why
  this shipped undetected twice. Two-finger pan is unaffected.
- **Pressure silently ran at a quarter of your tablet's resolution** (#27). The tablet is asked how
  many levels it has exactly once, at startup — and a Bluetooth tablet that has idled out isn't
  visible at that moment, so a 4096-level pen quietly ran at 1024 with nothing said anywhere. Both
  halves of the bridge agreed on the wrong number, so drawing still worked and there was no symptom
  beyond coarser strokes. The last resolution the hardware actually reported is now remembered
  across launches, and the tablet is asked once more just before SAI starts — the last moment the
  answer can still be changed safely. An explicit setting is never second-guessed.

- **Upgrading the app now actually updates the bridge** — and without this, none of the above would
  have reached you. The DLL that does the work lives inside the Wine prefix, and it was only ever
  copied there during first-time setup or an explicit reinstall. So installing a new version left
  the *old* DLL in place: you would have got the new app, none of the fix, and every reason to
  believe the fix didn't work. The prefix copy is now compared against the one in the app on every
  launch and replaced when it differs.
- **The DLL log states which build it is.** "Is the fix even loaded?" was previously unanswerable
  from the log, so a stale DLL looked identical to a broken fix.

### Internal
- `CLICK_DEDUP_MS` is shared between the DLL and its tests as `WTC_CLICK_DEDUP_MS`, so the two
  cannot drift apart on the boundary.
- The comment at the shared hook's install site claimed each feature *"still decides for itself
  inside click_hook_proc"*. That half was never written — it is now, along with a warning that a
  third consumer of that hook needs its own flag rather than widening an existing one.

## [0.1.10] — 2026-07-27

### Added
- **Two-finger scroll pans the canvas** instead of zooming (#24). Pinch already zoomed, so both
  gestures did the same thing and the natural way to move around the canvas was missing — on
  macOS, pinch zooms and two-finger scroll pans. Like pinch, this needs **no new permission**:
  the DLL rewrites the wheel message from inside SAI's own process and posts the arrow keys SAI
  binds to *Scroll View*. Tune with `WT_PAN_UNIT` (default 70), disable with `WT_NO_SCROLL_PAN=1`,
  flip sideways direction with `WT_PAN_INVERT_X=1`.

### Fixed
- **The macOS arrow no longer sits on top of SAI's brush cursor** (#20). One flag carried two
  different facts: *the pen is in range* (about the pen) and *the pen is what you're using*
  (about your hands). Any mouse or trackpad event cleared it, and since proximity events only
  fire on **transitions**, a pen already resting on the tablet never fired a new one to undo
  that — so nothing told SAI a pen existed. Clicking Launch with the trackpad was enough to
  trigger it. The two are now separate, with a one-second mouse-idle grace so SAI can still
  paint with the mouse, verified in use.
- **The same conflation in the menu-strip suppression**, which claimed the pen had left range
  whenever it hovered over SAI's menu row. That is the *"comes back a few seconds into drawing"*
  half of the same report — passing near the top of the window silently revoked the pen.
- **The DLL log no longer drowns itself**: the "click dedup: OFF by default" notice was emitted
  from producer housekeeping on every iteration (2055 spam lines out of 2111 in a field capture).

### Known
- **SAI's "Discharging of recovery point into file took a fatal error"** (#25) is **not caused by
  this project**. Reproduced with our DLL entirely out of the process (`WINEDLLOVERRIDES=wintab32=b`),
  on two SAI builds, two Wine versions, fresh prefixes and reset SAI settings. Workaround:
  *Others → Options → History and Recovery*. Full investigation recorded in the issue.
- **The menu-bar pen icon is still missing** (#14).

## [0.1.9] — 2026-07-27

### Added
- **Pinch to zoom** (#22). Two fingers apart/together on the trackpad now zooms SAI, at the
  cursor rather than the canvas centre. Notably this needed **no new permission**: the obvious
  route (synthesising events with `CGEvent.post`) requires Accessibility, which this project
  deliberately shed — but `wintab32.dll` already runs *inside* SAI, so the Mac side merely
  observes the gesture on the tap it already uses for the tablet and the DLL posts
  `WM_MOUSEWHEEL` from within SAI's own process. Disable with `WT_NO_PINCH_ZOOM=1`.
- **Universal binary — Intel Macs are supported again** (#6). Both slices are cross-compiled, so
  no Intel hardware is needed to build them; the x86_64 slice was verified by actually running it
  under Rosetta rather than assumed to work. `UNIVERSAL=0` builds host-only while iterating.
- **Documentation site** at
  <https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/> — install, troubleshooting,
  how it works, and engineering notes recording the decisions and the mistakes behind them.
  Plain GitHub Pages Jekyll: no Node, no build step, nothing to keep up to date.

### Fixed
- **First strokes after switching back to SAI now have pressure** (#9), and the macOS arrow no
  longer lingers over SAI's brush cursor at launch. Entering proximity emitted *nothing*, so SAI
  wasn't told a pen had arrived until it actually moved — and the hover keepalive couldn't cover
  the gap either, since it requires `lastPressure == 0` while `lastKeyP` stays at `-1` until the
  first sample. Proximity-enter now emits a hover sample, which announces the pen and unblocks
  the keepalive.
- **The DLL log no longer drowns itself.** The "click dedup: OFF by default" notice was emitted
  from producer housekeeping on every iteration; a field capture came back 2055 spam lines out of
  2111, burying the packet flow the log exists to show.

### Known
- **The macOS arrow can still reappear later in a session** (#20). The launch case above is fixed;
  a second cause remains — any plain mouse or trackpad event clears the in-proximity flag, which
  stops the keepalive, and a pen already resting in range sends no new proximity event to restore
  it. Cosmetic; drawing is unaffected.
- **The menu-bar pen icon is still missing** (#14). Five theories tested and disproven.
- **Releases remain ad-hoc signed** (#23), so macOS will not prompt for Input Monitoring — it has
  to be added by hand, once. Signing properly needs a paid Apple Developer Program membership.
  The install page says so plainly rather than implying a prompt will appear.

## [0.1.8] — 2026-07-27

### Added
- **Pressure now follows your tablet instead of a hard-coded 1024** (#21). The pen's HID
  tip-pressure element carries a logical range, and its size *is* the level count — so the app
  asks the hardware rather than guessing. No model lookup table; works for any vendor. Wacom
  reports it on the **vendor** digitizer page `0xff0d` rather than the standard `0x0d`, which is
  why a first attempt found nothing; both are accepted. A Wacom Intuos BT S answers 4096, so
  that hardware now gets 4× the resolution it was previously given.
- **Pressure levels** picker in Settings — Auto (the default) plus 1024 / 2048 / 4096 / 8192 —
  and it **explains itself**: *"Wacom Intuos BT S reports 4096 levels — using that"*, or with two
  tablets *"2 tablets connected — following the highest…"*, or *"no tablet reported a pressure
  range — using the safe default 1024"*. Choosing more levels than the hardware has warns first,
  because that spreads the same steps over a wider range and surfaces sensor noise as wobbly
  stroke width rather than giving finer control.
- **Jitter deadband**, scaled to the chosen resolution. This is what made higher resolutions
  usable: de-duplication compared pressure for *exact* equality, so 1024-level quantisation had
  been silently filtering sensor noise. Removing it without a replacement made stroke widths
  visibly wobble. The deadband keeps that noise rejection at any level count.
- **Pen feel** — a response curve (`out = in ^ gamma`) from Very soft to Very firm, applied on
  our side before the value is sent, so it needs no agreement with the DLL and **no SAI restart**.
  Endpoints are pinned (0→0, 1→1), so full press always stays full press. Defaults to Normal
  (linear) on purpose: it stacks with the Wacom driver's own curve and SAI's per-brush Min Size.
- **Test pen shows the raw tablet value** and a count of distinct raw values seen — an empirical
  read of what the hardware really sends, so upsampling can be told apart from real detail.

### Fixed
- **`make-app.sh` now signs with a real identity when the machine has one.** It defaulted to
  ad-hoc on the reasoning that a distinct identity per build keeps permissions from entangling.
  That was backwards: macOS attaches Input Monitoring to a code identity, and an ad-hoc signature
  has no Team ID and a fresh hash every build — so there was nothing durable to grant to. The
  permission was lost on every rebuild, the permission list filled with duplicate entries, and
  macOS never showed a prompt at all. `SIGN_ID="-"` forces ad-hoc (which is what CI gets anyway).
- **Grant… opens System Settings again.** A well-meant "ask me again" branch returned early and
  skipped the one step that actually worked, bouncing the app back into the same dialog — an
  infinite loop. Resetting the permission is still available as its own button, off the main path.

## [0.1.7] — 2026-07-26

### Fixed
- **The app could mistake ITSELF for SAI.** Three window scans matched any window whose owner
  name contained "wine" or "sai" — and *"SAI Pen Pressure"* contains "sai". The winner was
  picked by area, and Wine's window (1007×554) beat ours (726×760) by about 1%, so merely
  resizing our window would have pointed the wake, the menu-strip dead zone and the
  "has SAI closed?" check at our own window. Now excluded by PID.
- **A stale `wintab32.dll` can no longer survive an app update.** The helper and the DLL are a
  matched pair sharing a wire format with no version field, but the DLL only reached the
  prefix during setup — so updating the app left the old one in place indefinitely.
  `ensureBridgeUpToDate()` now byte-compares the installed DLL against the shipped one on
  every launch and heals it.
- **The license now works on the new "Major Renovated" SAI build too.** Where SAI reads the
  `.slc` changed between builds: older Ver.2 builds read it from the folder holding `sai2.exe`,
  the **2026-07-12 Technical Preview Major Renovated** build reads it from a **`settings`**
  folder. Putting it in the wrong one is indistinguishable from an invalid license — SAI just
  refuses to save, with no hint that the file is merely misplaced. The certificate is 128 bytes,
  so the app and `install.sh` now write **both** locations (and restore both after a rebuild),
  so whichever build you run finds its own.

### Added
- **`Show ▸` buttons** on the *Installed in Wine* and *SAI license* rows — one click to the
  folder SAI actually runs from, and to the certificate itself. No more guessing where things
  landed; previously this was buried in Developer mode behind an ambiguous "Prefix" button.
- **The license row says which locations are covered**, not just "installed" — *"in both
  locations"*, or *"only next to sai2.exe"* / *"only in settings/"*. That distinction is
  invisible otherwise, and it's the difference between SAI saving and refusing to.
- **SAI's build date** in the *Installed in Wine* row, read from SAI's own `history.txt`
  (survives renamed folders, unlike guessing from the folder name). Deliberately the date
  only — inferring the *branch* from a cutoff date would be wrong, since SYSTEMAX updates
  both branches and a later Stable build would be misclassified.
- **"Ask again"** on the Input Monitoring row when the permission is missing: clears just this
  app's own entry (`tccutil reset ListenEvent <bundle id>`) so macOS shows the native prompt
  again, instead of making you add the app by hand. It can only ever *remove* a grant — you
  still approve in System Settings — and it asks first.
- README documents both downloads on <https://www.systemax.jp/en/sai/devdept.html> — the
  newest **2026-07-12 Major Renovated** preview (which has a **dark theme**:
  *Window → Window Color → Dark Colors*) and the older Technical Preview Stable Version —
  and explains the license-location difference between them.

### Changed
- The setup window's footer lines are one line each instead of wrapping to two.

## [0.1.6] — 2026-07-26

### Fixed
- **CRITICAL — the pen could not draw at all on 0.1.5** (#19). 0.1.5's click de-dup installed a
  `WH_GETMESSAGE` hook that rewrote left-button messages to `WM_NULL` within 400 ms of a
  pen-tip transition, scoped "to the main window only" on the reasoning that dialogs are
  separate windows. But **the canvas is a child of the main window too**, so the hook ate the
  `WM_LBUTTONDOWN` that starts every stroke, ~6 ms after each pen-down:
  ```
  PEN DOWN press=218
  CLICK dedup: ate msg=0x201 dt=6ms      (0x201 = WM_LBUTTONDOWN)
  ```
  WinTab pressure kept arriving perfectly the whole time (`fetched=274/274`, `gaps=0`,
  `press` up to 1023/1023), so every diagnostic looked healthy while nothing painted — and
  **no amount of reinstalling could help, because the bug shipped inside `wintab32.dll`**.
  The de-dup is now **opt-in** (`WT_CLICK_DEDUP=1`); the default favours drawing, and #8 is
  reopened. Diagnose this class of problem with `WT_DEBUG=1`, which writes `C:\wtlog.txt`.
- **Changing the SAI folder did nothing** (#11). `ensureSetup()` returned early whenever
  `sai2.exe` already existed in the prefix, so a newly picked folder was never copied — the
  window showed the new path while SAI kept running the old build. The prefix now records
  which source it was built from and re-copies when they disagree.
- **The setup window froze once SAI launched** (#12). `refresh()` bailed out entirely while
  `running`, so nothing updated for the rest of the session. Status rows now always refresh.
- **`install.sh` rejected quoted paths** (#16). `read` takes the line literally, so
  `'/Users/me/SAI 2'` was checked *with* the quotes. Input is now normalised (surrounding
  quotes, stray whitespace, trailing slash, `~`).
- **The app mistook itself for SAI.** Three window scans matched any owner containing "wine"
  or "sai" — and *"SAI Pen Pressure"* contains "sai". Selection was by area, and Wine's window
  beat ours by 1%, so a slight resize would have pointed the wake, the menu-strip dead zone
  and the "has SAI closed?" check at our own window. Now excluded by PID.
- **Menu-bar icon** is an `applepencil` SF Symbol template image instead of the 🖊 emoji,
  which is a dark-grey glyph that all but vanished on a dark menu bar. (Icon only — #14, the
  item landing off-position, is still open.)

### Added
- **Reset everything & reinstall** and **Uninstall** (#10). Real recovery at last: wipe the
  Wine prefix, forget remembered folders, optionally remove Wine — and only offer to remove
  Wine when *this app* installed it, so a Wine you keep for other Windows programs is safe.
  Your own SAI folder and your licence are never touched.
- **SAI licence (.slc) row** (#13). Copies the certificate into `drive_c/SAI2` — the folder SAI
  actually reads — and keeps a copy so a rebuild restores it. Optional, never a blocker: SAI
  runs and draws without one, it just can't save. The UI states plainly that licences come
  from SYSTEMAX and that this project is unaffiliated and cannot supply one.
- **Set up everything automatically** — walks all five steps, waits for the Wine download to
  finish, finds your SAI folder via Spotlight, and resumes wherever it stopped.
- **Wine installs in-app with a live progress bar** instead of a Terminal window.
- **Developer mode** (#15) — logs, the three folders that matter, **Copy diagnostics**,
  a **Health check** that verifies every moving part (DLL hash, registry overrides, licence,
  permission), and a **session recorder** that diffs event counters over a window you choose.
- **Three-tier setup window** (#3): Simple hides satisfied rows, Settings reveals the full
  checklist, Developer adds the tools. The window auto-sizes to whichever tier is open.
- `install.sh --install-license`, `--repair`, `--rebuild`, `--help`.

### Changed
- **Source vs installed are now separate rows** (#18). SAI is *copied into* the prefix; the
  folder you pick is only needed to install or reinstall. Showing one "Using:" line made
  people edit their own SAI folder — most often to drop in the `.slc` — and see nothing happen.
- Steps that can't run yet are greyed with the reason (⏳), since the bridge installs *into*
  the Wine prefix and is meaningless before Wine and a source folder exist.
- **The `.command` launcher no longer pins the repo** (#17). `install.sh` copies the helper to
  `~/Library/Application Support/SAIPenPressure/bin/`, so the working copy can be moved or
  deleted. The installer now points at the app, and the script says plainly which features
  the CLI path lacks (no menu-bar icon, no Wake SAI, no auto-wake).

## [0.1.5] — 2026-07-25

> ⚠️ **Do not use 0.1.5** — the pen cannot draw. See #19; fixed in 0.1.6.

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

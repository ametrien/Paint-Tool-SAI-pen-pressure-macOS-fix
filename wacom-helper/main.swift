// main.swift — where the app starts, and the SetupController that owns its window.
//
// This file is the only one that runs statements, so everything whose ORDER
// matters is here: the command-line switches, the settings read before the pen
// is sampled, the self-test hooks, the developer (terminal) mode, and at the
// very bottom the app itself. Top-level `let`s here initialise in file order;
// globals in every other file initialise the first time they are used.
//
// Where the rest lives:
//   PenEngine.swift     the event tap and the stream of samples to the DLL
//   PressureCore.swift  the pure rules of that stream (unit-tested)
//   TabletDetect.swift  what tablet is connected, and its pressure levels
//   SelfTests.swift     the hooks tests/run-tests.sh drives the binary through
//   SetupWindow.swift   building the window and laying it out
//   PenUI.swift         the Pen tab          PenViews.swift  the views it draws
//   AutoWake.swift      waking a stuck SAI
//   ...and one file per remaining tab or concern; sources.txt lists them all.
//
// Build:  swiftc -O -o wacom-pressure-helper $(bash ../tools/sources.sh helper)
// Run:    ./wacom-pressure-helper   (from Terminal.app, NOT Claude Code)
// Needs:  System Settings → Privacy & Security → Input Monitoring, granted to
//         the terminal that runs this. (No Accessibility needed — Cmd->Ctrl is
//         handled by Wine.)

import AppKit
import CoreGraphics
import Foundation
import AVFoundation
import AVKit
import IOKit.hid       // IOHIDCheckAccess/RequestAccess — live Input-Monitoring status

// --version: print the build's version and exit (useful in bug reports).
// Packaged app: the version make-app.sh stamped from the git tag. Bare dev
// binary: "dev (unbundled)".
if CommandLine.arguments.contains("--version") {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    print(v ?? "dev (unbundled)")
    exit(0)
}

// Output file the DLL reads. Configurable via WT_PRESSURE_FILE so the tool
// isn't tied to one prefix (needed for distribution); defaults to the standard
// location so existing setups keep working with no env var.
let outPath: String = {
    if let p = ProcessInfo.processInfo.environment["WT_PRESSURE_FILE"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return NSString(string: "~/SAI2-pressure/drive_c/wt_pressure.txt").expandingTildeInPath
}()

// Verbose console logging (per-sample "captured=" spam, virtual-desktop info).
// Off by default (faster, quiet); set WT_VERBOSE=1 to enable while developing.
// Startup banner, warnings and errors always print.
let verbose = ProcessInfo.processInfo.environment["WT_VERBOSE"] != nil

// EXPERIMENT (WT_NO_HOVER=1): don't stream hover packets — only presses and the
// pen-up that ends a stroke. Used to isolate SAI's pen-vs-mouse suppression:
// if pen taps on SAI's top menu work in this mode, the suppression is driven by
// our continuous hover stream (fixable by gating hover); if they still fail,
// it's triggered by the tap's own packets (not fixable without breaking canvas).
// Side effects while ON (expected, the reasons hover streaming exists): brush
// cursor lags the pen while hovering; OS arrow cursor may flicker back.
let noHover = ProcessInfo.processInfo.environment["WT_NO_HOVER"] != nil

// ============================================================================
// APP-BUNDLE MODE — when launched as "SAI Pen Pressure.app" (with --app).
// First run: pick the SAI folder, create the Wine prefix, install our DLL.
// Every run: launch SAI alongside the pressure engine; quit when SAI closes.
// Run from a terminal WITHOUT --app and none of this happens (dev mode).
// The Input Monitoring permission attaches to the .app itself.
// ============================================================================
// App mode when launched as the .app bundle (its main executable is THIS binary
// directly — no launcher script, so downloaded/quarantined apps still open) or
// when forced with --app. Running the bare binary from a terminal = dev mode.
// Load the stored pressure resolution before anything samples the pen.
// Unset -> 1023, the long-standing default.
let _pmaxInit: Void = { PressureCore.maxPressure = savedMaxPressure()
                        applyFeel(savedFeel()) }()
let isAppMode = CommandLine.arguments.contains("--app") || Bundle.main.bundlePath.hasSuffix(".app")
// Wine prefix the app manages. Override with SAI_PREFIX (e.g. to test from
// scratch in a throwaway location without touching a real setup).
let appPrefix: String = {
    if let p = ProcessInfo.processInfo.environment["SAI_PREFIX"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return NSString(string: "~/SAI2-pressure").expandingTildeInPath
}()

/// A string literal for inside an osa() script. AppleScript only escapes
/// backslash and double quote; newlines are fine inside its quotes.
func osaQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
func osa(_ src: String) -> String? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", src]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (s?.isEmpty ?? true) ? nil : s
}
func alertUser(_ msg: String) { _ = osa("display dialog \(msg.debugDescription) buttons {\"OK\"} with icon note") }

// Diagnostic log for the "wake SAI" feature. Wake EVENTS are rare
// (user/return-triggered) so they're always logged — field debugging of
// issue #2 was blind without them. The chatty per-second keepAlive lines
// stay opt-in behind WT_WAKELOG.
let wakeLogOn = ProcessInfo.processInfo.environment["WT_WAKELOG"] != nil
func wlog(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let path = "/tmp/sai-wake.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

@discardableResult
func runProc(_ exe: String, _ args: [String], env: [String: String] = [:], wait: Bool = true) -> Process {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    if !env.isEmpty { var e = ProcessInfo.processInfo.environment; env.forEach { e[$0] = $1 }; p.environment = e }
    try? p.run(); if wait { p.waitUntilExit() }; return p
}
func wineBin() -> String? {
    let def = "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"
    if FileManager.default.isExecutableFile(atPath: def) { return def }
    if let e = ProcessInfo.processInfo.environment["WINE"], FileManager.default.isExecutableFile(atPath: e) { return e }
    return nil
}
// ============================================================================
// THE PREFIX. SAI is COPIED into a Wine prefix and run from THERE — the folder
// you pick is a source, not a live dependency. Everything that actually runs
// lives under these paths.
// ============================================================================
let prefixSAIDir = "\(appPrefix)/drive_c/SAI2"
let prefixSAIExe = "\(prefixSAIDir)/sai2.exe"

func saiInstalledInPrefix() -> Bool { FileManager.default.fileExists(atPath: prefixSAIExe) }

// The source folder the prefix was LAST BUILT FROM. Comparing it against the
// currently-chosen folder is what makes "Change…" mean something: if they
// disagree, the prefix is stale and must be re-copied (issue #11).
func installedSrcPath() -> String? {
    guard let s = try? String(contentsOfFile: appSupport() + "/installed-src.txt", encoding: .utf8) else { return nil }
    let p = s.trimmingCharacters(in: .whitespacesAndNewlines); return p.isEmpty ? nil : p
}
func setInstalledSrcPath(_ p: String) {
    try? p.write(toFile: appSupport() + "/installed-src.txt", atomically: true, encoding: .utf8)
}
/// true when what's installed doesn't match what's selected, so Launch must re-copy.
/// Upgrades from older versions have no marker yet — treat those as NOT stale so
/// nobody gets a surprise reinstall on first run of this build.
func prefixIsStale() -> Bool {
    guard saiInstalledInPrefix() else { return true }
    guard let want = savedSAIPath(), let have = installedSrcPath() else { return false }
    return want != have
}

// ---- licence (.slc) --------------------------------------------------------
// SAI reads its certificate from the folder it RUNS in, i.e. inside the prefix.
// Dropping it into your own SAI folder does nothing (issue #13). We also keep a
// stashed copy so a full prefix rebuild can put it back automatically.
/// Remembered until history.txt changes: the setup window shows it every
/// second, and reading and splitting the file each time held up the pen
/// (RefreshCache.swift).
let g_saiBuildDate = FileStampCache<String?>()
func saiBuildDate() -> String? {
    g_saiBuildDate.value(for: "\(prefixSAIDir)/history.txt") { readSAIBuildDate() }
}
func readSAIBuildDate() -> String? {
    guard let text = try? String(contentsOfFile: "\(prefixSAIDir)/history.txt", encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n", maxSplits: 400, omittingEmptySubsequences: true) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 10, t.dropFirst(4).first == "-", t.dropFirst(7).first == "-" else { continue }
        if t.split(separator: "-").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return t }
    }
    return nil
}

func saiBuildLabel() -> String? { saiBuildDate().map { "SAI build \($0)" } }

/// How a setup step reports itself to the UI (issue #28).
///
/// A step announces the span of the bar it owns and roughly how long it takes,
/// rather than a single "we are at 40%" number. That is what lets the bar keep
/// moving *during* a step: `wineboot` prints nothing parseable and takes about
/// a minute, so a per-step number would freeze the bar for the longest part of
/// the job — which is exactly the "it looks stuck" complaint.
///
///   from/to   the slice of the 0…1 bar this step occupies
///   label     what to say while it runs
///   expected  typical duration in seconds, for the creep (an estimate, and
///             treated as one — see setupStep)
typealias SetupProgress = (_ from: Double, _ to: Double, _ label: String, _ expected: Double) -> Void

/// Back-compat entry point used by the launch path.
func ensureSetup(_ saiSrc: String, _ wine: String) -> Bool {
    performSetup(saiSrc, wine, mode: .ensure)
}

// Mac-friendly modifier keys, done by WINE itself at the driver level, inside
// Wine apps only: Command -> Ctrl (undo/redo/save) and, by default, left
// Option -> Alt (SAI's eyedropper). The Keys tab can change each of the four.
// This replaces an earlier CGEventTap-based remap that synthesized wrong
// shortcuts and needed the Accessibility permission. Idempotent + fast, so we
// run it on EVERY launch — existing prefixes get the keys too, and a change on
// the Keys tab lands the next time SAI starts. Cmd+Tab / Cmd+Q etc. are
// unaffected (those never reach Wine).
func applyWineShortcutRemap(_ wine: String) {
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    // All four, "N" included: a key switched back off must be turned off in
    // Wine too, not just left as it was.
    for (name, value) in storedKeyMapping().wineValues {
        runProc(wine, ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver",
                       "/v", name, "/t", "REG_SZ", "/d", value, "/f"], env: env)
    }
}

// Self-test hooks for tests/run-tests.sh (SelfTests.swift). Inert without
// their environment variables; each one exits when it has run.
//
// Placement matters: top-level `let`s in main.swift initialise in file order,
// and an earlier version of the first hook read prefixSAIDir before it existed
// and silently reported "SAI isn't installed".
runSelfTestIfAsked()

/// The encoder running alongside SAI, turning frames into video as they are
/// captured.
///
/// Without it, raw frames pile up at roughly 3 MB each and a long session
/// reaches gigabytes before anyone presses Make video. With it, frames are
/// consumed within a second of being written and disk stays flat — the video
/// itself becomes the storage.
var g_liveEncoder: Process?

var g_wine = ""   // resolved during setup; used to launch SAI after the tap is granted

// SETUP ONLY (runs before the pressure tap): resolve Wine, pick the SAI folder,
// build the prefix + install the bridge. Does NOT launch SAI — that happens
// only after the tap is created, so a first run without permissions doesn't
// leave an orphaned SAI window behind (you'd otherwise have to restart).
func runAppSetup() {
    guard let wine = wineBin() else {
        // Wine missing — offer to install it automatically in a visible Terminal
        // (real download progress; the user sees exactly what's happening).
        let installer = Bundle.main.resourcePath.map { "\($0)/install-wine.sh" }
        let choice = osa("button returned of (display dialog \"Wine isn't installed. SAI needs it to run.\n\nInstall it automatically now? (~300 MB download; you'll see progress in a Terminal window, then reopen this app.)\" buttons {\"Do it manually\", \"Install Wine\"} default button \"Install Wine\" with icon note)")
        if choice == "Install Wine", let sh = installer, FileManager.default.fileExists(atPath: sh) {
            _ = osa("tell application \"Terminal\" to do script \"bash '\(sh)'\"")
            _ = osa("tell application \"Terminal\" to activate")
            alertUser("Installing Wine in Terminal. Watch the progress there. When it says it's done, just reopen SAI Pen Pressure.")
        } else {
            alertUser("Download Gcenx 'Wine Staging', put 'Wine Staging.app' in /Applications, then reopen this app.\n\nhttps://github.com/Gcenx/macOS_Wine_builds/releases")
        }
        exit(0)
    }
    g_wine = wine
    var sai = savedSAIPath()
    if sai == nil {
        sai = osa("POSIX path of (choose folder with prompt \"Select your SAI Ver.2 folder (the one that contains sai2.exe)\")")
        if let s = sai { saveSAIPath(s) }
    }
    guard let saiSrc = sai else { exit(0) }                 // user cancelled the picker
    guard ensureSetup(saiSrc, wine) else { exit(1) }
}

// The pen path itself (the tap, the samples, the keepalive) is PenEngine.swift.

// virtual-desktop bounds now + on every display change (monitor plug/unplug)
refreshVirtualBounds()
let reconfigCB: CGDisplayReconfigurationCallBack = { _, _, _ in refreshVirtualBounds() }
CGDisplayRegisterReconfigurationCallback(reconfigCB, nil)

// ---- permission helpers (used by both modes / the wizard) ------------------
func inputMonitoringGranted() -> Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
func requestInputMonitoring() {
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)     // shows the system prompt
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
}
func installWineViaTerminal() {
    guard let sh = Bundle.main.resourcePath.map({ "\($0)/install-wine.sh" }), FileManager.default.fileExists(atPath: sh) else {
        NSWorkspace.shared.open(URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases")!); return
    }
    // The same build the in-app install picks, not "the newest" (see
    // WineStatusCore.updateTarget). Reuses the choice the in-app install just
    // made, when there is one, so the fallback after a failed install does not
    // wait on the network again on the main thread.
    let url = g_wineInstallURL ?? wineInstallTarget().url
    let cmd = WineStatusCore.installCommand(script: sh, url: url)
    _ = osa("tell application \"Terminal\" to do script \"\(cmd)\"")
    _ = osa("tell application \"Terminal\" to activate")
}
func saiReady() -> Bool { savedSAIPath() != nil }

// ============================================================================
//  ENTRY POINT
// ============================================================================
if !isAppMode {
    // Dev / terminal mode: start the engine right away and run.
    if !startPressureEngine() {
        print("ERROR: tap failed. Grant this terminal Input Monitoring, then re-run.")
        exit(1)
    }
    signal(SIGINT) { _ in try? "0".write(toFile: outPath, atomically: true, encoding: .ascii); exit(0) }
    print("wacom-pressure-helper running. Writing to \(outPath). Ctrl+C to quit.")
    CFRunLoopRun()
}

// ---- App mode: a small setup wizard (AppKit) -------------------------------
final class SetupController: NSObject, NSApplicationDelegate, NSTabViewDelegate {
    struct Req {
        let title, detail, fixTitle: String
        let ok: () -> Bool; let fix: () -> Void; let required: Bool
        var dynamicDetail: (() -> String)? = nil   // recomputed each refresh (e.g. show the chosen path)
        var keepButton: Bool = false               // keep the button visible even when satisfied (e.g. "Change…")
        var keepButtonTitle: String = "Change…"    // button label when satisfied (e.g. "Uninstall…" for Wine)
        // Order matters: our bridge is installed INTO the Wine prefix, so the
        // prefix step is meaningless until Wine exists and a source is chosen.
        // Steps that can't be done yet are greyed out with a reason instead of
        // offering a button that would just error.
        var enabledIf: (() -> Bool)? = nil
        var blockedHint: String = ""
        // Optional second button — used for "show me where this actually is",
        // which shouldn't be buried in Developer mode.
        var extraTitle: String? = nil
        var extraAction: (() -> Void)? = nil
        /// "Show ▸" only makes sense once the thing exists; the permission row's
        /// extra button is the opposite — it's the escape hatch for when it's
        /// still missing.
        var extraWhenSatisfied: Bool = true
    }
    var reqs: [Req] = []
    var window: NSWindow!
    var subtitle: NSTextField!
    var launchBtn: NSButton!
    var statusFields: [NSTextField] = []
    var detailFields: [NSTextField] = []
    var fixButtons: [NSButton] = []
    var extraButtons: [NSButton?] = []      // optional "Show ▸" per row
    var running = false
    // "Test Tablet Pressure" widgets — a live 0–100% bar so the user can confirm
    // the pen works BEFORE launching SAI.
    var testBtn: NSButton!
    var probeHint: NSTextField!
    var recvBar: PressureBar!
    var recvLabel: NSTextField!
    var recvRow: NSStackView!
    var sentCaption: NSTextField!
    var recvCaption: NSTextField!
    let probeStream = BridgeProbeStream()
    var testHint: NSTextField!
    var barRow: NSStackView!
    var pressureBar: PressureBar!
    var pressureLabel: NSTextField!
    var testing = false
    var testTimer: Timer?
    var testPeakSeen = 0        // highest raw level seen this test run
    var pressurePopup: NSPopUpButton!
    var pressureInfo: NSTextField!
    var feelPopup: NSPopUpButton!
    var gammaSlider: NSSlider!
    var gammaLabel: NSTextField!
    var floorSlider: NSSlider!
    var floorLabel: NSTextField!
    var fullAtSlider: NSSlider!
    var fullAtLabel: NSTextField!
    var curveView: GammaCurveView!
    /// The saved custom profiles (PenFeelCore; up to three), loaded once per window.
    var penProfiles: [PenProfile] = []
    /// The custom profile the dropdown last had selected, if any. Kept while
    /// the sliders move away from its stored values, so "Save changes to it"
    /// knows which profile is meant.
    var selectedProfile: String?

    // ---- window layout tiers -------------------------------------------------
    // SIMPLE (default): only what needs your attention, plus Launch. Once
    // everything is green this collapses to a title, a line of status and one
    // big button — which is all a returning user wants.
    // SETTINGS (disclosure): the full checklist — source / installed / licence —
    // plus the explanatory footers.
    // DEVELOPER (checkbox inside Settings): logs, prefix, diagnostics, console.
    var content: NSStackView!
    var rowViews: [NSStackView] = []
    var footerLabels: [NSTextField] = []
    var advanced = false
    var advancedBtn: NSButton!
    var allSetLabel: NSTextField!
    var autoBtn: NSButton!
    var autoRunning = false
    var secondaryRow: NSStackView!
    var devSection: NSStackView!
    // Tabs, added because the single column had grown past a screen: setup,
    // recording and the developer tools have nothing to do with each other, and
    // stacking them meant scrolling past all three to reach any one of them.
    var tabView: NSTabView!
    var recordingTab: NSStackView!
    var recEveryStrokeCheck: NSButton!
    var recFramesLabel: NSTextField!
    var recCheck: NSButton!
    var recMakeBtn: NSButton!
    var recDiscardBtn: NSButton!
    var recLengthPopup: NSPopUpButton!
    var recFolderLabel: NSTextField!
    // The Timelapses tab (LibraryUI.swift). libStore is a cache of the index for
    // the buttons to act on; refreshLibraryTab() reloads it from disk, so the
    // file stays the source of truth and this never drifts.
    var libraryTab: NSStackView!
    var libStack: NSStackView!
    var libFooter: NSTextField!
    var libScrollHeight: NSLayoutConstraint!
    // The Keys tab (KeysUI.swift). Nothing cached: the settings file is read on
    // every change, so it is the only copy of the truth.
    var keysTab: NSStackView!
    var keyPopups: [MacModifierKey: NSPopUpButton] = [:]
    var keysWarning: NSTextField!
    var keysRestartNote: NSTextField!
    var keysNote: NSTextField!
    /// Set when a key changes while SAI is open; cleared once SAI has closed,
    /// because the next start picks the change up on its own.
    var keysNeedSAIRestart = false
    // Advanced › Display (test), DisplayUI.swift: Retina mode and SAI's language.
    var retinaCheck: NSButton!
    var displayHint: NSTextField!
    /// Language: SAI's menus and the font for Chinese, Japanese and Korean text.
    var langPopup: NSPopUpButton!
    var fontPathLabel: NSTextField!
    var fontCopyButton: NSButton!
    var displayRestartNote: NSTextField!
    /// Like keysNeedSAIRestart, for the Display settings.
    var displayNeedsSAIRestart = false
    // Advanced › Wine (WineUI.swift).
    var wineStatusLabel: NSTextField!
    var wineActionBtn: NSButton!
    /// Run once after an in-app Wine install succeeds (Install Wine, Update Wine).
    var afterWineInstall: (() -> Void)?
    /// Setup is looking up which Wine to install (a second click must wait).
    var wineChoosing = false
    var libStore: LibraryStore?
    var settingsTab: NSStackView!
    var settingsScratch: PenScratchView!
    var scratchRow: NSStackView!
    var setupReportBtn: NSButton!
    var autoWakeCheck: NSButton!
    var recUsageLabel: NSTextField!
    var recButtonRow: NSStackView!
    var recApplyHint: NSTextField!
    var recApplyPending = false
    var recPreview: AVPlayerView!
    var recPreviewLabel: NSTextField!
    var recHidePreviewBtn: NSButton!
    var devCheck: NSButton!
    var devUpdateRows: [NSView] = []      // shown even without developer mode
    var console: NSTextView!
    var consoleScroll: NSScrollView!
    let rowWidth: CGFloat = 500

    func lbl(_ s: String, _ size: CGFloat, bold: Bool = false, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        l.textColor = color
        return l
    }

    /// Written once per launch, so a log someone pastes into an issue identifies
    /// itself. #29 cost two rounds of questions that this answers up front:
    /// which build, which Wine prefix, whether our DLL is the one installed, and
    /// what the registry override actually says.
    func logSessionHeader() {
        var os = ProcessInfo.processInfo.operatingSystemVersionString
        os = os.replacingOccurrences(of: "Version ", with: "")
        let tablets = detectTablets()
        let tabletLine = tablets.isEmpty ? "none detected"
            : tablets.map { t in
                let range = t.fullScale.map { "\($0 + 1) levels" } ?? "range not reported"
                return "\(t.name) [\(t.transport)] \(range)"
              }.joined(separator: ", ")
        wlog("=== session start · SAI Pen Pressure \(currentVersion()) · macOS \(os) ===")
        wlog("prefix \(appPrefix) · sai2.exe present: \(saiInstalledInPrefix())")
        wlog("bridge: our DLL installed: \(bridgeDLLMatchesApp()) · override: \(BridgeCheck.overrideValue(inUserReg: readUserReg() ?? "") ?? "MISSING")")
        wlog("wine: \(wineBin() ?? "NOT FOUND")")
        wlog("tablet: \(tabletLine)")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        logSessionHeader()
        NSApp.activate(ignoringOtherApps: true)
        reqs = [
            Req(title: "Wine (runs SAI on Mac)", detail: "Gcenx Wine Staging in /Applications", fixTitle: "Install Wine…",
                ok: { wineBin() != nil },
                fix: { [weak self] in
                    // In-app install with a live progress bar (markWineInstalledByUs
                    // is set inside, so "Reset everything" can tell our Wine from
                    // one the user keeps for other Windows apps).
                    if wineBin() == nil { self?.installWineInApp() } else { self?.uninstallWine() }
                }, required: true,
                keepButton: true, keepButtonTitle: "Uninstall…"),
            // SOURCE vs INSTALLED are two separate rows on purpose (issue #18).
            // SAI is COPIED out of the folder you pick; it then runs from the
            // Wine prefix. Showing only "Using: <your folder>" made people edit
            // that folder (e.g. drop the .slc in) and wonder why nothing changed.
            Req(title: "PaintTool SAI folder (source)", detail: "No folder chosen yet. Click Choose.", fixTitle: "Choose…",
                ok: { saiReady() }, fix: { [weak self] in self?.chooseSAI() }, required: true,
                dynamicDetail: { savedSAIPath().map { "Copied from: \(($0 as NSString).abbreviatingWithTildeInPath)" }
                                 ?? "No folder chosen yet. Click Choose." },
                keepButton: true),
            Req(title: "Installed in Wine (what actually runs)", detail: "Not installed yet.", fixTitle: "Install…",
                ok: { saiInstalledInPrefix() && !prefixIsStale() },
                fix: { [weak self] in self?.reinstallMenu() }, required: true,
                dynamicDetail: {
                    let where_ = (prefixSAIDir as NSString).abbreviatingWithTildeInPath
                    if !saiInstalledInPrefix() { return "Not installed yet. Created on Launch." }
                    if prefixIsStale() { return "OUT OF DATE. Source folder changed, reinstall to apply." }
                    // Read from SAI's own history.txt, so it survives renamed folders.
                    return saiBuildLabel().map { "\(where_)  ·  \($0)" } ?? where_
                },
                keepButton: true, keepButtonTitle: "Reinstall…",
                enabledIf: { wineBin() != nil && saiReady() },
                blockedHint: "Needs Wine and a SAI folder first.",
                extraTitle: "Show ▸", extraAction: { [weak self] in self?.openSAIInWine() }),
            // THE BRIDGE ITSELF — a file in the prefix and a Wine setting that
            // decides whether that file is ever loaded. Both used to be assumed
            // rather than shown, and #29 was a machine where the assumption was
            // wrong: everything else on this checklist was green while SAI drew
            // with the plain mouse. While SAI runs, the detail line stops being
            // a check of our own files and becomes what the DLL reports from
            // INSIDE SAI: whether SAI opened a tablet, whether our samples
            // arrive, and whether SAI reads the packets we post.
            Req(title: "Pressure bridge (what carries pressure into SAI)",
                detail: "our wintab32.dll, plus the Wine setting that makes SAI load it",
                fixTitle: "Repair…",
                ok: { bridgeInstalledOK() },
                fix: { [weak self] in self?.repairBridge() }, required: true,
                dynamicDetail: { bridgeDetailLine() },
                keepButton: true, keepButtonTitle: "Repair…",
                enabledIf: { wineBin() != nil },
                blockedHint: "Needs Wine first."),
            // Optional (⚪️ not ❌): SAI launches without a licence, you just
            // can't save. Lives next to the INSTALLED row because that's the
            // folder it has to land in.
            // OPTIONAL, and deliberately not a blocker: SAI installs, launches and
            // draws without a licence — it just can't save. Marked ⚪️, never ❌.
            Req(title: "SAI license (.slc), optional", detail: "Your own license from SYSTEMAX. Only needed to save.", fixTitle: "Install…",
                ok: { installedLicenseName() != nil },
                fix: { [weak self] in self?.chooseLicense() }, required: false,
                dynamicDetail: {
                    if let n = installedLicenseName() { return "\(n) · \(licenseLocationSummary())" }
                    if !slcFiles(in: licenseStashDir()).isEmpty {
                        return "Saved copy will be restored when SAI is installed."
                    }
                    return "Not installed. SAI runs and draws, but can't save."
                },
                keepButton: true,
                extraTitle: "Show ▸", extraAction: { [weak self] in self?.revealLicense() }),
            Req(title: "Input Monitoring permission", detail: "lets the app read your tablet's pressure", fixTitle: "Grant…",
                ok: { inputMonitoringGranted() }, fix: { [weak self] in self?.grantInputMonitoring() }, required: true,
                // The button stays after the permission is granted, because the
                // list is still worth visiting: every build of this app is a
                // separate entry in it, so old ones pile up and sit there dead.
                // With no button at all, a green row was a dead end.
                keepButton: true, keepButtonTitle: "Show…",
                extraTitle: "Ask again", extraAction: { [weak self] in self?.resetOwnPermission() },
                extraWhenSatisfied: false),
        ]
        buildWindow()
        refresh()
        announceUpdateIfJustUpdated()
        // The bridge is asserted when Launch is pressed — but SAI can be started
        // without ever pressing it (a .command launcher, Wine directly), and a
        // repair that only happens on one path is the one-shot that #29 was made
        // of. Checking costs a file read; wine is only spawned when something is
        // actually wrong, and doing it here means simply opening this window is
        // enough to heal the prefix for whatever starts SAI next (#31).
        DispatchQueue.global().async { ensureBridgeOverride(wineBin()) }
        // On launch, actively ask for Input Monitoring — the ONLY permission this
        // app needs — via the native prompt (with an "Open System Settings"
        // button), so the user doesn't add the app manually. No-op if already
        // granted. (Cmd->Ctrl shortcuts are handled by Wine, so there's no
        // Accessibility permission to ask for anymore.)
        if !inputMonitoringGranted() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        // .common mode so the checklist keeps refreshing even while the window
        // is being interacted with (plain .default timers can stall).
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        // Reopened by Advanced › Display's "Close and reopen SAI": start SAI
        // again, as Launch would. A second later so the window is up first.
        if consumeRelaunchSAIMarker() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.launchTapped() }
        }

        // AUTO-ACTIVATE: when the Wine app comes to the foreground, force its
        // windows to become key. Under Wine on macOS the window often comes back
        // "greyed"/inactive at the Win32 level after an app switch, so SAI eats
        // your first click (its WM_MOUSEACTIVATE handler returns MA_NOACTIVATEANDEAT).
        // Re-activating here is what the manual Space-swipe does — it makes the
        // window key up front, so the click isn't wasted. Set WT_AUTOACTIVATE=0
        // to disable. (Needs no extra permission — plain NSRunningApplication API.)
        if ProcessInfo.processInfo.environment["WT_AUTOACTIVATE"] != "0" {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(appActivated(_:)),
                name: NSWorkspace.didActivateApplicationNotification, object: nil)
        }

        // Menu-bar rescue: a always-available "Wake SAI" button. If SAI ever comes
        // back "stuck"/greyed after an app switch, one click here forces a full
        // re-activation (what the 3-finger Space-swipe does) without switching
        // apps. Lives in the menu bar so it's reachable even while SAI is frontmost.
        setUpStatusItem()
        checkForUpdates()
        // Auto-wake driven by the REAL stuck signal (see the tap's plain-mouse
        // branch): the pen got demoted to a plain mouse over SAI's window while
        // the tablet stream went silent. Throttled + gated by the same toggle.
        g_onStuckDetected = { [weak self] in self?.autoWakeStuck() }
        // The wake HOTKEY (⌃⌥⌘Space) is detected by the pressure event tap (see
        // g_onWakeHotKey / tapCallback) — the same listen-only tap that reads the
        // tablet. Carbon's RegisterEventHotKey proved unreliable here (registered
        // but the event never arrived). The tap uses the Input Monitoring
        // permission we already have and fires globally, even while SAI is
        // frontmost. It only OBSERVES the key, so nothing else is affected.
        g_onWakeHotKey = { [weak self] in self?.wakeSAI() }
    }

    // ---- auto-wake (issue #2) ------------------------------------------------
    // The state only; AutoWake.swift has the methods and says why each exists.
    // Toggle live from the 🖊 menu; WT_NO_AUTOWAKE=1 starts it off.
    var autoWake = ProcessInfo.processInfo.environment["WT_NO_AUTOWAKE"] == nil
    var bouncing = false          // true while WE are re-activating (ignore our own events)
    var lastReactivate = Date.distantPast
    var wakeSeq = 0               // counts the wake requests sent to the DLL (bumpWin32Wake)

    var statusItem: NSStatusItem?
    var screenNotice = BridgeCheck.ScreenNotice.none   // see watchScreenNotice (#37)

    @objc func reinstallTapped() { showSetupWindow(); reinstallMenu() }
    @objc func licenseTapped()   { showSetupWindow(); chooseLicense() }

    func applicationDidBecomeActive(_ note: Notification) { refresh() }   // re-check when refocused

    // ---- version / update check -----------------------------------------------
    var versionLabel: NSTextField!
    var updateLabel: NSTextField!
    var updateBtn: NSButton!
    var notesBtn: NSButton!
    var autoUpdateCheck: NSButton!
    var redactCheck: NSButton!
    var latestTag: String?
    var latestNotes: String = ""
    var latestZipURL: String?        // the asset the in-app update installs
    var autoUpdateTried = false      // once per launch, whatever the answer
    var updateChecking = false       // a check is on its way
    var updateCheckFailed = false    // the last check got no answer: the row offers "Check again"
    let repoSlug = "ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix"

    // Clicking our Dock icon should bring SAI forward — people think of this as
    // "the app I run SAI with", so focusing our (usually minimized) setup window
    // instead is surprising. The 🖊 menu bar still opens Settings any time.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if running, let target = saiTarget() {
            wlog("dock reopen -> focusing SAI pid=\(target.processIdentifier)")
            bounceToSAI(target)
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // Auto-wake trigger #3: we just LOST focus to SAI (e.g. you had our Settings
    // window open and clicked back onto SAI). The activation notification alone
    // doesn't reliably un-stick that hand-off, so nudge it from our side too.
    func applicationDidResignActive(_ note: Notification) {
        guard autoWake, running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, !self.bouncing,
                  Date().timeIntervalSince(self.lastReactivate) > 0.6,
                  let front = NSWorkspace.shared.frontmostApplication else { return }
            let hay = "\(front.bundleIdentifier ?? "") \(front.localizedName ?? "") \(front.executableURL?.path ?? "")".lowercased()
            guard hay.contains("wine") || hay.contains("sai") else { return }
            guard let target = self.saiTarget() else { return }
            self.lastReactivate = Date()
            wlog("autoWake(resign): owner pid=\(target.processIdentifier)")
            self.bounceToSAI(target)
        }
    }

    /// Quitting the app ends the recording too. SAI closing is the usual way a
    /// session finishes, but not the only one — and segments left behind look
    /// to anyone reading the folder like nothing was recorded at all.
    func applicationWillTerminate(_ note: Notification) {
        stopChildrenBeforeExit()        // the encoder AND the Test pen probe
        finalizeTimelapseNow()
    }

    func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        refreshRecordingTab()
        if item?.identifier as? String == "Videos" { refreshLibraryTab() }
        // The console only refreshed while the old "Settings" disclosure was
        // open, so in the tabbed layout it showed as an empty black box.
        if item?.identifier as? String == "Advanced" { updateConsole() }
        applyLayout()
    }

    /// Whether the setup window can be seen: open and not minimized. No window
    /// yet (the self-tests build tabs without one) counts as seen, so those
    /// paths behave as they always did.
    func windowIsOnScreen() -> Bool {
        guard let w = window else { return true }
        return w.isVisible && !w.isMiniaturized
    }

    func refresh() {
        // Keep the Recording tab current while it is being looked at. Without
        // this it showed whatever it said when you switched to it, so drawing
        // for ten minutes still read "Nothing recorded yet". Only when that tab
        // is actually selected: it stats the frames folder, and there is no
        // reason to do that once a second behind a tab nobody is looking at.
        if (tabView?.selectedTabViewItem?.identifier as? String) == "Keys" {
            refreshKeysRestartNote()
        }
        if (tabView?.selectedTabViewItem?.identifier as? String) == "Advanced" {
            refreshDisplayRestartNote()
        }
        if (tabView?.selectedTabViewItem?.identifier as? String) == "Recording" {
            refreshRecordingTab()
        }
        // Keep the live encoder alive for as long as SAI is. It used to start
        // only from launchSAIApp(), so restarting the app while SAI was already
        // open meant nothing was recorded for the rest of that session — and
        // nothing said so. This also brings it back if it died on its own.
        if let p = g_liveEncoder, !p.isRunning { g_liveEncoder = nil }
        if g_liveEncoder == nil, timelapseRecordingEnabled(), saiWindowIsOpen() {
            startLiveEncoder()
        }
        // A window nobody can see has nothing to refresh. While you draw, this
        // window is minimized, and everything below ran anyway, once a second,
        // on the thread the pen is read on: about 55 ms each time, with pen
        // samples waiting up to 20 ms behind it (measured 2026-11-13). The
        // encoder check above is the one thing that must go on unseen. Coming
        // back to the window refreshes it at once (applicationDidBecomeActive)
        // and within a second in any case.
        guard windowIsOnScreen() else { return }
        // The STATUS ROWS always update, even while SAI is running (issue #12).
        // They used to be skipped entirely once `running` was set, so changing
        // the SAI folder or installing a licence mid-session showed no change at
        // all. Only the subtitle and the Launch button are frozen while running.
        for (i, r) in reqs.enumerated() {
            let ok = r.ok()
            // A step whose prerequisites aren't met is shown greyed with the
            // reason, rather than offering a button that could only fail.
            let enabled = r.enabledIf?() ?? true
            statusFields[i].stringValue = ok ? "✅" : (enabled ? (r.required ? "❌" : "⚪️") : "⏳")
            if !enabled && !ok {
                detailFields[i].stringValue = r.blockedHint
            } else if let dd = r.dynamicDetail {
                detailFields[i].stringValue = dd()                              // e.g. show the chosen folder
            }
            rowViews[i].alphaValue = enabled ? 1.0 : 0.45
            fixButtons[i].isEnabled = enabled
            // Nothing to reveal until the thing actually exists on disk.
            if i < extraButtons.count, let extra = extraButtons[i] {
                extra.isHidden = (r.extraWhenSatisfied ? !ok : ok)
                extra.isEnabled = enabled
            }
            if r.keepButton {                       // stays visible so you can change/uninstall it
                fixButtons[i].isHidden = false
                fixButtons[i].title = ok ? r.keepButtonTitle : r.fixTitle
            } else {
                fixButtons[i].isHidden = ok
            }
        }
        refreshPressureUI()
        applyLayout()                           // rows appear/vanish as state changes
        guard !running else { return }          // SAI is up; leave the CTA alone
        // Launch needs Wine + SAI; Input Monitoring is verified for real by
        // actually creating the tap on Launch (the permission check can read
        // ❌ even when the tap will work), so it doesn't hard-block here.
        let canLaunch = wineBin() != nil && saiReady()
        launchBtn.isEnabled = canLaunch
        if !canLaunch {
            subtitle.stringValue = "Add the missing items above, then Launch."
        } else if !inputMonitoringGranted() {
            subtitle.stringValue = "Ready. Grant Input Monitoring so pressure works, then Launch."
        } else {
            subtitle.stringValue = "All set. Click Launch."
        }
    }

    // ---- licence ------------------------------------------------------------
    // This project does NOT supply, generate or resell licences and has no
    // connection to SYSTEMAX. All it does is copy a certificate the user
    // already bought into the folder SAI actually reads. Say so plainly, in
    // the UI, before the file picker — not just in the README.
    static let saiOfficialURL = "https://www.systemax.jp/en/sai/"

    // ---- in-app Wine install with live progress -----------------------------
    // install-wine.sh needs no sudo (it only writes to /Applications), so we can
    // run it as a child process and show curl's progress in the window instead
    // of sending the user to a Terminal and hoping they watch it. Terminal
    // remains the fallback if the bundled script is missing or the run fails.
    var wineRow: NSStackView!
    var wineBar: PressureBar!
    var wineLabel: NSTextField!
    // The setup steps reuse the same bar/label as the Wine download: only one
    // long operation ever runs at a time, and a second identical row would just
    // be more to keep in sync.
    var setupTimer: Timer?

    var wineProc: Process?
    var wineOutBuf = ""

    // ---- dev mode (issue #15) ----------------------------------------------
    // Off by default. Toggled from the menu-bar item and the right-click Dock
    // menu; persisted so it survives a relaunch.
    var devMode: Bool = FileManager.default.fileExists(atPath: appSupport() + "/devmode.txt") {
        didSet {
            let p = appSupport() + "/devmode.txt"
            if devMode { try? "1".write(toFile: p, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(atPath: p) }
            rebuildMenus()
        }
    }

    // ---- timelapse recording -----------------------------------------------
    // Off by default and persisted, like dev mode. The flag is read when SAI
    // LAUNCHES (it becomes WT_TIMELAPSE in the Wine environment), so toggling it
    // while SAI is already running does nothing until the next launch — the menu
    // title says so rather than leaving people to wonder.
    var timelapseOn: Bool = timelapseRecordingEnabled() {
        didSet {
            // Inverted: the file marks OFF, so the default (no file) records.
            let p = timelapseOffMarker()
            if timelapseOn { try? FileManager.default.removeItem(atPath: p) }
            else { try? "1".write(toFile: p, atomically: true, encoding: .utf8) }
            rebuildMenus()
            refreshRecordingTab()
        }
    }

    var timelapseFramesDir: String { "\(appPrefix)/drive_c/sai-timelapse/frames" }

    // ---- session recorder ---------------------------------------------------
    // "Record from here to there, then tell me what happened." Snapshots the
    // event counters and the wake log, then diffs them on stop — so you can
    // reproduce a glitch and get a self-contained report instead of eyeballing
    // a live log. Saved, shown in the console, and copied to the clipboard.
    struct RecSnapshot {
        let t: Date, seq: Int, tabletPtr: Int, tabletMouse: Int
        let prox: Int, plainMouse: Int, wakeLines: Int
    }
    var recording: RecSnapshot?
    var recMaxPressure = 0
    var recPressSamples = 0
    var recTimer: Timer?
    var recBtn: NSButton!

    @objc func launchTapped() {
        guard let wine = wineBin(), let sai = savedSAIPath() else { refresh(); return }
        stopTest()                          // tidy up the live test UI if it was open
        g_wine = wine
        launchBtn.isEnabled = false
        subtitle.stringValue = "Setting up… (first time can take a minute)"
        DispatchQueue.global().async {
            // An app update ships a new helper AND a new DLL, but the DLL only
            // reaches the prefix if setup runs. Heal it here so the two halves
            // can never drift apart (issue #21).
            ensureBridgeUpToDate(wine)
            // ...and the half of it that lives in the registry. Without this
            // key Wine loads its OWN wintab32 and every line above is wasted
            // work — a prefix in that state used to stay in it forever (#29).
            ensureBridgeOverride(wine)
            let ok = ensureSetup(sai, wine)
            DispatchQueue.main.async {
                guard ok else { self.subtitle.stringValue = "Setup failed. Re-check the SAI folder."; self.refresh(); return }
                if startPressureEngineOnce() {
                    self.running = true
                    launchSAIApp()
                    self.subtitle.stringValue = "Running. Pressure is active, close SAI to quit."
                    self.window.miniaturize(nil)
                } else {
                    self.relaunchForPermission()
                }
            }
        }
    }

}

let g_setup = SetupController()     // strong ref (NSApplication.delegate is weak)
// `kill`, `killall` or closing the terminal the app was started from would
// otherwise end it on the spot, with no cleanup at all (ChildCleanup says why).
ChildCleanup.exitCleanlyOnSignals { endRecordingAndExit() }
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.regular)
nsApp.delegate = g_setup
nsApp.run()

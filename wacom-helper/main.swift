// wacom-pressure-helper (Phase 1: CGEventTap) — reads real pen pressure +
// position from a low-level event tap and streams it to our custom wintab32.dll.
//
// Why CGEventTap (not NSEvent global monitor): a global monitor is passively
// observed and Apple coalesces/throttles it, so fast pen samples were dropped
// (missing strokes / dots). An event tap sits IN the event stream — far less
// coalescing — and exposes the native tabletEventPointPressure field.
//
// Transport: each captured sample is one UDP datagram to 127.0.0.1:47800,
// stamped with a monotonic sequence number so the DLL can detect any loss.
// The file (wt_pressure.txt) is still written as fallback + `echo 0` kill switch.
//
// Build:  swiftc -O -o wacom-pressure-helper main.swift
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
                        PressureCore.pressureGamma = savedGamma() }()
let isAppMode = CommandLine.arguments.contains("--app") || Bundle.main.bundlePath.hasSuffix(".app")
// Wine prefix the app manages. Override with SAI_PREFIX (e.g. to test from
// scratch in a throwaway location without touching a real setup).
let appPrefix: String = {
    if let p = ProcessInfo.processInfo.environment["SAI_PREFIX"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return NSString(string: "~/SAI2-pressure").expandingTildeInPath
}()










// ---- pressure resolution (issue #21) ---------------------------------------
// The helper and the DLL must agree on full-scale pressure, and SAI reads the
// axis once at WTOpen. So the choice is stored on the mac side and mirrored
// into the prefix as C:\wt_pmax.txt BEFORE SAI launches; the DLL reads that at
// load. One value, two readers, no way for them to disagree.
/// Ask the tablet how many pressure levels it actually has.
///
/// The pen's tip-pressure HID element carries a logical range, and its size IS
/// the level count — no model lookup table, works for any vendor. Wacom reports
/// it on the VENDOR digitizer page 0xff0d rather than the standard 0x0d (an
/// Intuos BT S answers 0…4095, i.e. 4096 levels), so accept both.
///
/// Returns the full-scale value (levels - 1), or nil when nothing answers —
/// no tablet plugged in, a driver that hides the element, or a device that
/// simply doesn't report one. Callers fall back to 1023.
struct TabletInfo {
    let name: String        // e.g. "Wacom Intuos BT S"
    let fullScale: Int      // levels - 1
}

/// Every connected device that reports a tip-pressure range.
func detectTablets() -> [TabletInfo] {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    defer { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }
    guard let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return [] }
    var found: [TabletInfo] = []
    for d in devs {
        guard let els = IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
        var best = 0
        for e in els {
            let page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e)
            // 0x30 = Tip Pressure, on the standard or the vendor digitizer page.
            guard usage == 0x30, page == 0x0D || page == 0xFF0D else { continue }
            let span = Int(IOHIDElementGetLogicalMax(e)) - Int(IOHIDElementGetLogicalMin(e))
            // Ignore nonsense: some elements advertise the full 32-bit range.
            guard span >= 255, span <= PressureCore.maxPressureCeiling else { continue }
            best = max(best, span)
        }
        guard best > 0 else { continue }
        let maker = (IOHIDDeviceGetProperty(d, kIOHIDManufacturerKey as CFString) as? String) ?? ""
        let prod  = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "tablet"
        // "Wacom Co.,Ltd." + "Intuos BT S" reads badly; keep it short.
        let short = maker.split(separator: " ").first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,")) ?? ""
        let name = (short.isEmpty || prod.lowercased().contains(short.lowercased())) ? prod : "\(short) \(prod)"
        found.append(TabletInfo(name: name, fullScale: best))
    }
    return found.sorted { $0.fullScale > $1.fullScale }
}

/// The tablet we follow in Auto mode: the highest-resolution one connected.
func detectTablet() -> TabletInfo? { detectTablets().first }

func detectTabletFullScale() -> Int? { detectTablet()?.fullScale }






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
func saiBuildDate() -> String? {
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

// Mac-friendly shortcuts: make WINE map Command -> Control (undo/redo/save/etc.)
// itself, inside Wine apps only, at the driver level. This replaces an earlier
// CGEventTap-based remap that synthesized wrong shortcuts and needed the
// Accessibility permission. Idempotent + fast, so we run it on EVERY launch —
// existing prefixes (set up before this feature) get the keys too. Cmd+Tab /
// Cmd+Q etc. are unaffected (those never reach Wine).
func applyWineShortcutRemap(_ wine: String) {
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    for key in ["LeftCommandIsCtrl", "RightCommandIsCtrl"] {
        runProc(wine, ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver",
                       "/v", key, "/t", "REG_SZ", "/d", "Y", "/f"], env: env)
    }
}
/// Self-test entry point for the SAI update, used by tests/run-tests.sh.
///
/// This is the only code in the app that deletes a user's SAI folder and puts
/// it back, so it is worth a real test rather than a careful reading. The test
/// points SAI_PREFIX at a throwaway prefix, runs the update, and checks what
/// survived. Guarded by an environment variable, so it is inert in normal use.
///
/// Placement matters: top-level `let`s in main.swift initialise in file order,
/// and an earlier version of this hook read prefixSAIDir before it existed and
/// silently reported "SAI isn't installed".
if let src = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_UPDATE"] {
    let result = updateSAIFromFolder(src)
    print(result ?? "OK")
    exit(result == nil ? 0 : 1)
}

/// Self-test hook for the library: file whatever the encoder left in staging,
/// print where each session went, and exit. Filing MOVES a session's only copy
/// into a drawing's folder, so it is tested against a real throwaway folder
/// rather than reasoned about — the same treatment, for the same reason, as the
/// SAI-update hook above. Inert without the environment variable.
/// Self-test hook: build the Timelapses tab and print what it actually laid out.
///
/// This exists because the tab shipped BLANK. Every row was built, added and
/// unhidden — and drawn at zero size, because a stack view used as a scroll
/// view's documentView is laid out by constraints and it had been left on
/// autoresizing translation. Nothing about the code reads as wrong; only the
/// measured frames say so, which is exactly what this prints.
/// Self-test hook for the uninstall: the most destructive path in the app.
///
/// removeWine is ALWAYS false here. The real thing can move Wine Staging to the
/// Trash, and a test that did that would reach outside its throwaway directories
/// and take a real application off the machine running it.
if let mode = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_UNINSTALL"] {
    let c = SetupController()
    c.performUninstall(keepLicense: mode == "keep", removeWine: false)
    let fm = FileManager.default
    print("prefix exists=\(fm.fileExists(atPath: appPrefix))")
    for f in ["config.txt", "devmode.txt", "installed-src.txt"] {
        print("\(f) exists=\(fm.fileExists(atPath: appSupport() + "/" + f))")
    }
    print("stash \(slcFiles(in: licenseStashDir()).joined(separator: ",")) ")
    let videos = timelapseOutputFolder()
    let names = ((try? fm.contentsOfDirectory(atPath: videos)) ?? []).sorted()
    print("videos \(names.joined(separator: ","))")
    print("index exists=\(fm.fileExists(atPath: timelapseLibraryPath()))")
    exit(0)
}

/// Self-test hook for the licence: the one file in this app nobody can recreate.
///
/// It drives the exact sequence performSetup(.rebuild) performs around the point
/// where it deletes the whole prefix — adopt whatever is in the prefix, delete
/// the prefix, put it back — because that deletion is where a certificate would
/// be lost, and every call on the path is a silent `try?`.
///
/// Wine is not involved and cannot be: the wineboot in performSetup takes a
/// minute and needs a real Wine. What is being tested is the rescue, not the
/// prefix build.
if let step = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_LICENSE"] {
    switch step {
    case "rebuild":
        // Exactly performSetup's order, and nothing else.
        adoptLicenseFromSourceFolder(prefixSAIDir)
        try? FileManager.default.removeItem(atPath: appPrefix)
        restoreStashedLicenses()
    case "adopt-source":
        // Picking a SAI folder that already holds a certificate.
        if let n = adoptLicenseFromSourceFolder(CommandLine.arguments.dropFirst().first ?? "") {
            print("adopted \(n)")
        }
    case "install":
        let src = CommandLine.arguments.dropFirst().first ?? ""
        print("installed=\(installLicenseFile(src))")
    case "restore":
        restoreStashedLicenses()
    default:
        break
    }
    for d in licenseDirs {
        for f in slcFiles(in: d) { print("prefix \((d as NSString).lastPathComponent)/\(f)") }
    }
    for f in slcFiles(in: licenseStashDir()) { print("stash \(f)") }
    exit(0)
}

/// Self-test hook: where would this session record to? Guards the upgrade path,
/// where a marker left by an older version pointed outside staging.
if ProcessInfo.processInfo.environment["SAIPP_SELFTEST_SESSIONBASE"] != nil {
    print(timelapseSessionBase())
    exit(0)
}

if let dir = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_TABLAYOUT"] {
    _ = NSApplication.shared
    let c = SetupController()
    let tab = c.buildLibraryTab()
    // A window, because view layout outside one is undefined — and the bug
    // being guarded against is precisely a view that never gets a size.
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                     styleMask: [.titled], backing: .buffered, defer: false)
    tab.translatesAutoresizingMaskIntoConstraints = true
    tab.autoresizingMask = [.width, .height]
    tab.frame = w.contentView!.bounds
    w.contentView?.addSubview(tab)
    w.layoutIfNeeded()
    func dump(_ v: NSView, _ depth: Int) {
        let name = (v as? NSTextField)?.stringValue
            ?? (v as? NSButton)?.title
            ?? String(describing: type(of: v))
        print(String(format: "%@%@ %.0fx%.0f", String(repeating: "  ", count: depth),
                     name, v.frame.width, v.frame.height))
        for s in v.subviews { dump(s, depth + 1) }
    }
    dump(tab, 0)
    print("rows \(c.libStack.arrangedSubviews.count) "
          + "stack \(Int(c.libStack.frame.width))x\(Int(c.libStack.frame.height))")
    // Counted from the model, never by grepping the dump above: an NSButton has
    // an inner view carrying the same title on some macOS versions, so counting
    // rows by their button text read 2 locally and 4 on CI.
    func hoverRows(_ v: NSView) -> Int {
        (v is HoverVideoView ? 1 : 0) + v.subviews.reduce(0) { $0 + hoverRows($1) }
    }
    let drawn = c.libStore?.lib.drawings.count ?? 0
    print("rows drawings=\(drawn) loose=\(hoverRows(tab) - drawn)")

    // Changing the videos folder must reload the list in place — the whole point
    // being that you do not have to quit the app to see the other folder.
    if let switchTo = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_FOLDERSWITCH"] {
        c.setTimelapseFolder(switchTo)
        w.layoutIfNeeded()
        print("--- after switching to \(switchTo)")
        dump(tab, 0)
        print("rows \(c.libStack.arrangedSubviews.count) "
              + "stack \(Int(c.libStack.frame.width))x\(Int(c.libStack.frame.height))")
    }

    // Hovering plays the video. The tracking area is AppKit's business; that a
    // row is wired to a player, and lets go of it again, is ours.
    if ProcessInfo.processInfo.environment["SAIPP_SELFTEST_HOVER"] != nil {
        var rows: [HoverVideoView] = []
        func collect(_ v: NSView) {
            if let hv = v as? HoverVideoView { rows.append(hv) }
            for sub in v.subviews { collect(sub) }
        }
        collect(tab)
        print("hoverable \(rows.count)")
        if let first = rows.first {
            first.beginPreview()
            w.layoutIfNeeded()
            print("hover begin previewing=\(first.isPreviewing)")
            // The preview must stay inside the thumbnail. An unclipped player
            // layer draws the video at its own size over the rows below — it
            // covered half the tab before this was checked.
            let inside = first.subviews.allSatisfy {
                $0.frame.width <= first.bounds.width + 0.5
                    && $0.frame.height <= first.bounds.height + 0.5
            }
            let pf = first.previewFrame
            let layerFits = pf.width > 0 && pf.width <= first.bounds.width + 0.5
                && pf.height <= first.bounds.height + 0.5
            print("hover box \(Int(first.bounds.width))x\(Int(first.bounds.height))"
                  + " video \(Int(pf.width))x\(Int(pf.height))"
                  + " inside=\(inside) layerFits=\(layerFits) clips=\(first.layer?.masksToBounds ?? false)")
            first.endPreview()
            print("hover end previewing=\(first.isPreviewing)")
        }
        // Moving across rows must leave ONE playing, not one per row crossed.
        for r in rows { r.beginPreview() }
        print("hover concurrent \(rows.filter(\.isPreviewing).count) of \(rows.count)")
        for r in rows { r.endPreview() }
    }
    _ = dir
    exit(0)
}

if let dir = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_LIBRARY"] {
    let store = LibraryStore(videosDir: dir, indexPath: dir + "/.library.json")
    if store.recoveredFromBrokenIndex { print("recovered from a broken index") }
    for f in store.fileFinishedSessions() {
        let d = store.lib.drawing(id: f.drawingId)
        print("filed \(f.pieceFile) -> \(d?.folder ?? "?")"
              + (f.askAbout.map { " ask:\(store.lib.drawing(id: $0)?.folder ?? "?")" } ?? ""))
    }
    // Answering the question is part of the same path and needs the same proof.
    if ProcessInfo.processInfo.environment["SAIPP_SELFTEST_CONFIRM"] == "same",
       let p = store.lib.pending.first {
        store.confirmSame(p)
        print("confirmed same -> \(store.lib.drawing(id: p.candidateId)?.folder ?? "?")")
    }
    for d in store.lib.drawings.sorted(by: { $0.folder < $1.folder }) {
        print("drawing \(d.folder) [\(d.title)]: \(d.ordered.map(\.file).joined(separator: ", "))")
    }
    exit(0)
}

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

// OUR OWN app is called "SAI Pen Pressure", which contains "sai" — so every
// window scan that looks for SAI by owner name was also matching our setup
// window. It was decided purely by area: Wine's window (1007x554) beat ours
// (726x760) by about 1%, so resizing our window was enough to make the app
// treat ITSELF as SAI — wrong wake target, wrong menu strip, wrong "is SAI
// still open". Always exclude our own process.
let g_myPID = ProcessInfo.processInfo.processIdentifier





// (app mode is driven by the setup wizard at the bottom of this file)

// FULL VIRTUAL DESKTOP bounds (union of all displays), in the global display
// coordinate space that CGEvent.location uses (top-left origin, y-down, points).
// We report the pen position within THIS combined space so a 2nd monitor maps
// correctly instead of producing a doubled cursor. Single screen: this is just
// that screen. Refreshed on display reconfiguration (connect/disconnect).
var vX = 0.0, vY = 0.0, vW = 1440.0, vH = 900.0

func refreshVirtualBounds() {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        let f = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        vX = 0; vY = 0; vW = Double(f.width); vH = Double(f.height); return
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    // top-left global space, same as CGEvent.location
    let rects = ids.map { id -> (x: Double, y: Double, w: Double, h: Double) in
        let b = CGDisplayBounds(id)
        return (Double(b.minX), Double(b.minY), Double(b.width), Double(b.height))
    }
    guard let u = PressureCore.virtualUnion(of: rects) else { return }
    vX = u.x; vY = u.y; vW = u.w; vH = u.h
    if verbose { print("virtual desktop: origin(\(Int(vX)),\(Int(vY))) size \(Int(vW))x\(Int(vH))") }
}

// --- UDP socket to the DLL --------------------------------------------------
let udpSock = socket(AF_INET, SOCK_DGRAM, 0)
var udpAddr = sockaddr_in()
udpAddr.sin_family = sa_family_t(AF_INET)
udpAddr.sin_port = in_port_t(UInt16(47800).bigEndian)
udpAddr.sin_addr.s_addr = inet_addr("127.0.0.1")

func sendUDP(_ line: String) {
    guard udpSock >= 0 else { return }
    line.withCString { cs in
        withUnsafePointer(to: &udpAddr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                _ = sendto(udpSock, cs, strlen(cs), 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// --- sample emit (globals so the C-ABI tap callback can reach them) ---------
var seq = 0
var lastKeyP = -1, lastKeyX = Int.min, lastKeyY = Int.min
var gTap: CFMachPort?
// KEEPALIVE state: while the pen is in proximity we resend the last sample at a
// low rate even if it hasn't moved, so SAI keeps thinking a pen is present and
// keeps the OS arrow cursor hidden (it flickered back during quiet gaps). Cleared
// on pen-leave / mouse use so mouse painting still works.
// PEN IN RANGE — a fact about the PEN, changed only by real proximity/tablet
// events. Deliberately NOT cleared by mouse activity: that conflation is what
// left the macOS arrow over SAI's cursor (issue #20), because a pen already
// resting on the tablet fires no new proximity event to undo it.
var penInRange = false
// ...and separately, when the mouse was last used. The keepalive pauses while
// the mouse is active so SAI can still paint with it, then resumes on its own.
var lastPlainMouseAt: CFAbsoluteTime = 0
// Pen is over SAI's menu row: stay silent so SAI takes the plain mouse click.
var overMenuStrip = false
var lastSendMs = CFAbsoluteTimeGetCurrent()

/// Record what the hardware actually reported. Counting DISTINCT raw values
/// over a firm press-and-release is an empirical read of the tablet's real
/// resolution: a 4096-level tablet cannot produce more than 4096 of them, no
/// matter what full scale we ask for.
func noteRawPressure(_ pr: Double) {
    g_lastRawPressure = pr
    guard pr > 0 else { return }
    if g_rawSeen.count > 60_000 { g_rawSeen.removeAll() }   // bounded
    g_rawSeen.insert(Int((pr * 1_000_000).rounded()))
}

// ---- PINCH TO ZOOM (issue #22) ---------------------------------------------
// macOS pinch is a "magnify" gesture Wine never translates, so SAI only zooms on
// two-finger scroll. We DON'T synthesise mac events for this (that needs the
// Accessibility permission this project deliberately dropped) — we just observe
// the gesture on the tap we already run for the tablet, and hand a step count to
// our DLL, which posts the wheel message from inside SAI's own process.
//
// Magnification arrives as a continuous delta while SAI zooms in fixed steps, so
// accumulate and emit a step each time the total crosses the threshold: a slow
// pinch still does something, a fast one doesn't fling the zoom.
let zoomStep = 0.06
let pinchZoomOff = ProcessInfo.processInfo.environment["WT_NO_PINCH_ZOOM"] != nil
var g_zoomAccum = 0.0
var g_zoomSteps = 0

func noteMagnify(_ mag: Double) {
    guard !pinchZoomOff, mag != 0 else { return }
    g_zoomAccum += mag
    var changed = false
    while g_zoomAccum >=  zoomStep { g_zoomSteps += 1; g_zoomAccum -= zoomStep; changed = true }
    while g_zoomAccum <= -zoomStep { g_zoomSteps -= 1; g_zoomAccum += zoomStep; changed = true }
    guard changed else { return }
    try? "\(g_zoomSteps)".write(toFile: "\(appPrefix)/drive_c/wt_zoom.txt",
                                atomically: true, encoding: .ascii)
}

func writeFile(_ s: String) {
    try? s.write(toFile: outPath, atomically: true, encoding: .ascii)
}

func send(_ p: Int, _ xf: Int, _ yf: Int) {
    seq += 1
    let wf = Int(vW * 8), hf = Int(vH * 8)
    sendUDP("\(seq) \(p) \(xf) \(yf) \(wf) \(hf)")   // UDP: seq + sample
    writeFile("\(p) \(xf) \(yf) \(wf) \(hf)")        // file: sample (no seq)
    lastSendMs = CFAbsoluteTimeGetCurrent()
}

// ---- MENU-STRIP PASSTHROUGH (issue #1) -------------------------------------
// SAI's top menu row ("File", "Edit", …) ignores pen taps: while our WinTab
// stream says a pen is present, SAI de-dups and discards the pen's synthesized
// mouse click there (the menu is driven by mouse clicks, not WinTab packets).
// Fix: while the pen is over that strip, stream NOTHING. SAI then sees no pen,
// so the ordinary mouse click gets through and the menu opens. Over the canvas
// and panels the full pressure stream continues unchanged.
// Strip = the top `stripH` points of SAI's window (Wine title bar + menu row).
// Tune with WT_MENU_STRIP=<points>, disable with WT_MENU_STRIP=0.
let menuStripH: CGFloat = {
    if let s = ProcessInfo.processInfo.environment["WT_MENU_STRIP"], let v = Double(s) { return CGFloat(v) }
    return 58        // Wine title bar (~23pt) + menu row (~25pt) + margin
}()
var g_saiStrip = CGRect.zero          // in CGEvent.location space (top-left origin)
var g_saiWindow = CGRect.zero         // SAI's whole window rect (same space)
var g_lastDrawAt = Date.distantPast   // last time real pressure was emitted
// RAW pressure straight from the tablet, before any scaling of ours. Kept so the
// pen test can show what the hardware actually reports rather than what we
// derived from it — the only way to tell real resolution from upsampling.
var g_lastRawPressure: Double = 0
var g_rawSeen = Set<Int>()            // distinct raw values, keyed to 1e-6
var g_onMouseDown: ((CGPoint) -> Void)?   // set by the wizard: auto-wake on click

func refreshSAIStrip() {
    guard menuStripH > 0 else { g_saiStrip = .zero; return }
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var best = CGRect.zero, bestArea: CGFloat = -1
    for w in list {
        guard isForeignSAIWindow(w) else { continue }
        guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        let area = r.width * r.height
        if area > bestArea { bestArea = area; best = r }
    }
    g_saiWindow = best
    g_saiStrip = best.isEmpty ? .zero
        : CGRect(x: best.minX, y: best.minY, width: best.width, height: min(menuStripH, best.height))
}

// PEN-UP LATCH state (see PressureCore.upLatchAbsorbs): a pen-up is HELD for a
// short window instead of being sent immediately, so a pressure dip through
// zero (one physical touch reported as two) collapses back into one touch.
// (x, y) is where the pen went up; `at` when. Flushed by the timer, by the pen
// leaving proximity (no re-touch can follow), or by a genuine new touch.
var g_pendingUp: (x: Int, y: Int, at: CFAbsoluteTime)?
// latch window, tunable: WT_UP_LATCH=<ms> (default 150; 0 disables). Raise it
// if single taps still double occasionally; lower it if fast intentional
// double-taps get absorbed. Above ~200ms you enter human double-tap
// territory — a re-touch that slow is indistinguishable from intent.
let upLatchS: Double = {
    if let s = ProcessInfo.processInfo.environment["WT_UP_LATCH"], let v = Double(s) { return v / 1000 }
    return 0.15
}()

func flushPendingUp() {
    guard let up = g_pendingUp else { return }
    g_pendingUp = nil
    lastKeyP = 0; lastKeyX = up.x; lastKeyY = up.y
    send(0, up.x, up.y)
}

func emit(pressure: Int, loc: CGPoint) {
    // Over SAI's menu strip: go silent so SAI treats the pen as a plain mouse.
    if !g_saiStrip.isEmpty && g_saiStrip.contains(loc) {
        g_pendingUp = nil                      // strip ends the touch right here
        if lastKeyP > 0 {                      // pen was down -> end the stroke cleanly
            lastKeyP = 0
            send(0, lastKeyX, lastKeyY)
        }
        // Do NOT clear penInRange here: the pen is still very much in range,
        // it is merely over the menu. Claiming otherwise is the same conflation
        // that caused issue #20 elsewhere. A separate flag suppresses the
        // keepalive while over the strip, and clears itself the moment the pen
        // moves back onto the canvas.
        overMenuStrip = true
        return
    }

    overMenuStrip = false          // got past the strip check: back on the canvas

    // coordinate mapping + clamp + dedup rules live in PressureCore (unit-tested)
    let p = PressureCore.clampPressure(pressure)
    // WT_NO_HOVER experiment: drop hover samples (p==0) unless they END a
    // stroke (previous sample was a press) — see the flag's comment up top.
    if noHover && p == 0 && lastKeyP <= 0 { return }
    let (xf, yf) = PressureCore.mapToVirtual(locX: loc.x, locY: loc.y, vX: vX, vY: vY, vH: vH)

    // --- pen-up latch ---------------------------------------------------------
    if p == 0 {
        if upLatchS > 0, lastKeyP > 0, g_pendingUp == nil {
            // pen just left the surface: HOLD the up; flush when the latch
            // window passes without a bounce. lastKeyP stays >0 so the stream
            // reads "still touching" until the up is actually sent.
            let up = (x: xf, y: yf, at: CFAbsoluteTimeGetCurrent())
            g_pendingUp = up
            DispatchQueue.main.asyncAfter(deadline: .now() + upLatchS + 0.01) {
                if let cur = g_pendingUp, cur.at == up.at { flushPendingUp() }
            }
        }
        // While a hold is pending, hover samples NEAR the tap spot stay
        // swallowed (that's the latch). But the moment the pen MOVES AWAY,
        // holding is pointless — a re-touch there wouldn't be absorbed — and
        // swallowing hover froze the brush cursor after every stroke, which
        // read as "drawing got laggier". Flush and resume live hover tracking.
        if let up = g_pendingUp {
            if abs(xf - up.x) <= 48 && abs(yf - up.y) <= 48 { return }   // same radius as upLatchAbsorbs
            flushPendingUp()
            // fall through: this sample continues as a normal hover packet
        }
    } else if let up = g_pendingUp {
        if PressureCore.upLatchAbsorbs(secondsSincePenUp: CFAbsoluteTimeGetCurrent() - up.at,
                                       xf: xf, yf: yf, upX: up.x, upY: up.y,
                                       latch: upLatchS) {
            g_pendingUp = nil                  // bounce: same touch continues
        } else {
            flushPendingUp()                   // genuine new touch: end the old one first
        }
    }

    // Deadband, not exact-equality: at higher resolutions sensor jitter would
    // otherwise become a packet per wobble (issue #21).
    if PressureCore.shouldSkip(p: p, xf: xf, yf: yf, lastP: lastKeyP, lastX: lastKeyX, lastY: lastKeyY,
                               deadband: PressureCore.pressureDeadband) { return }
    lastKeyP = p; lastKeyX = xf; lastKeyY = yf
    if p > 0 { g_lastDrawAt = Date() }        // "SAI is clearly alive" signal for auto-wake
    send(p, xf, yf)
    if verbose && (seq % 100 == 1 || p == 0) {
        print("captured=\(seq) pressure=\(p)/\(PressureCore.maxPressure)")
    }
}

// resend the last sample (keepalive) — keeps SAI's "pen present" state alive
// during a HOVER with no movement, so the OS cursor stays hidden. ONLY when the
// last sample was pen-up/hover (lastKeyP == 0): re-sending an actual press
// (lastKeyP > 0) made SAI register spurious extra clicks / feel glitchy.
var g_kaTick = 0
var g_evTabletPtr = 0, g_evTabletMouse = 0, g_evProx = 0, g_evPlainMouse = 0
var g_lastTabletEvAt = CFAbsoluteTimeGetCurrent()   // last time a real TABLET event arrived
var g_penEverSeen = false                           // this session uses a pen at all
let g_demotionWake = ProcessInfo.processInfo.environment["WT_DEMOTION_WAKE"] != nil   // experimental, off
var g_onStuckDetected: (() -> Void)?                // set by the wizard -> auto-wake
var g_lastPenInRange = false
var g_lastKAState = ""
func keepAlive() {
    // Log only TRANSITIONS — the arrow reappearing mid-session (issue #20) is a
    // state change, and a per-tick log would bury it the way the dedup notice
    // buried the packet flow.
    if penInRange != g_lastPenInRange {
        g_lastPenInRange = penInRange
        wlog("penInRange -> \(penInRange)  (overStrip=\(overMenuStrip) lastP=\(lastKeyP))")
    }
    let st = !penInRange ? "quiet: pen out of range"
           : overMenuStrip ? "quiet: over menu strip"
           : (CFAbsoluteTimeGetCurrent() - lastPlainMouseAt) <= 1.0 ? "quiet: mouse just used"
           : lastKeyP > 0 ? "quiet: pen is down (drawing)"
           : "keepalive active"
    if st != g_lastKAState { g_lastKAState = st; wlog("keepalive \(st)") }
    // Revive the tap if macOS ever disabled it (App Nap / timeout / user input).
    // The disable-event path only fires if our run loop is awake to receive it;
    // this poll (every 40ms) is the belt-and-suspenders that recovers the pen
    // stream even if we missed the event — the "recv freezes / no brush dot" bug.
    let enabled = gTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    if let t = gTap, !enabled { CGEvent.tapEnable(tap: t, enable: true) }
    // ~1s heartbeat: is our run loop even ticking, is the tap enabled, and are
    // we still capturing (seq)? Tells us if the mac tap is what's dying.
    g_kaTick += 1
    if wakeLogOn, g_kaTick % 25 == 0 { wlog("mac keepAlive: tick=\(g_kaTick) tapEnabled=\(enabled) captured(seq)=\(seq) | tabletMouse=\(g_evTabletMouse) PLAINmouse=\(g_evPlainMouse) penSeen=\(g_penEverSeen) saiWin=\(g_saiWindow.isEmpty ? "EMPTY" : "\(Int(g_saiWindow.width))x\(Int(g_saiWindow.height))")") }
    if noHover { return }   // WT_NO_HOVER experiment: no hover keepalive at all
    if PressureCore.keepAliveShouldResend(penInRange: penInRange && !overMenuStrip, lastPressure: lastKeyP,
                                          secondsSinceLastSend: CFAbsoluteTimeGetCurrent() - lastSendMs,
                                          secondsSinceMouseUse: CFAbsoluteTimeGetCurrent() - lastPlainMouseAt) {
        send(lastKeyP, lastKeyX, lastKeyY)
    }
}

// --- the event tap ----------------------------------------------------------
// Only TABLET-sourced events drive WinTab. Real mouse/trackpad events are left
// untouched so SAI's own mouse painting still works — streaming hover packets
// for every mouse move told SAI a pen was always present and suppressed mouse
// paint entirely. A tablet-generated mouse event carries subtype tabletPoint(1).
func isTabletMouse(_ e: CGEvent) -> Bool {
    return e.getIntegerValueField(.mouseEventSubtype) == 1   // kCGEventMouseSubtypeTabletPoint
}

// Set by the app's wizard (app mode) to the "wake SAI" action; the event tap
// calls it when it sees the wake hotkey. nil in dev/terminal mode.
var g_onWakeHotKey: (() -> Void)?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    // Auto-wake trigger #2: a click. When SAI is ALREADY frontmost but stuck,
    // clicking it fires no app-activation notification at all, so the wizard
    // never hears about it — this is the only signal we get.
    if type == .leftMouseDown, let cb = g_onMouseDown {
        let loc = event.location
        DispatchQueue.main.async { cb(loc) }
    }
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        wlog("MAC TAP DISABLED (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")) -> re-enabling")
        if let t = gTap { CGEvent.tapEnable(tap: t, enable: true) }
    case .keyDown:
        // Global "wake SAI" hotkey: ⌃⌥⌘Space. Detected here (listen-only, never
        // consumed) rather than via Carbon RegisterEventHotKey, which didn't
        // deliver on this setup. 49 = kVK_Space.
        if event.getIntegerValueField(.keyboardEventKeycode) == 49 {
            let f = event.flags
            if f.contains(.maskControl) && f.contains(.maskAlternate) && f.contains(.maskCommand) {
                DispatchQueue.main.async { g_onWakeHotKey?() }
            }
        }
    case .tabletProximity:
        g_evProx += 1
        // pen entering/leaving range drives the keepalive (arrow stays hidden
        // while present, mouse can paint once the pen leaves)
        penInRange = event.getIntegerValueField(.tabletProximityEventEnterProximity) != 0
        if penInRange {
            // ENTERING range used to emit nothing, so SAI wasn't told a pen was
            // present until the pen actually MOVED. Two consequences (issue #20):
            // the macOS arrow stayed drawn over SAI's brush cursor in that gap,
            // and the hover keepalive couldn't start either — it requires
            // lastPressure == 0, but lastKeyP is -1 until the first sample.
            // Emitting one hover sample on entry closes both.
            emit(pressure: 0, loc: event.location)
        } else {
            emit(pressure: 0, loc: event.location)
            flushPendingUp()   // pen left range: no bounce can follow, end the touch now
        }
    case .tabletPointer:
        g_evTabletPtr += 1
        g_lastTabletEvAt = CFAbsoluteTimeGetCurrent(); g_penEverSeen = true
        penInRange = true
        let pr = event.getDoubleValueField(.tabletEventPointPressure)
        noteRawPressure(pr)
        emit(pressure: Int(PressureCore.curved(pr) * Double(PressureCore.maxPressure)), loc: event.location)
    case .leftMouseUp:
        if isTabletMouse(event) { emit(pressure: 0, loc: event.location) }   // pen tip lift (still hovering)
    case .mouseMoved, .leftMouseDown, .leftMouseDragged:
        if isTabletMouse(event) {
            g_evTabletMouse += 1
            g_lastTabletEvAt = CFAbsoluteTimeGetCurrent(); g_penEverSeen = true
            penInRange = true
            let pr = event.getDoubleValueField(.tabletEventPointPressure)
            noteRawPressure(pr)
            emit(pressure: Int(PressureCore.curved(pr) * Double(PressureCore.maxPressure)), loc: event.location)
        } else {
            g_evPlainMouse += 1
            // Note what the mouse did, but do NOT claim the pen has left:
            // it may well still be sitting on the tablet. The keepalive pauses
            // on this timestamp and resumes once the mouse goes idle.
            lastPlainMouseAt = CFAbsoluteTimeGetCurrent()
            // STUCK DETECTION: the Wacom driver demotes the pen to a PLAIN mouse
            // when SAI's window isn't properly foreground. Signature = plain-mouse
            // events arriving over SAI's window while the tablet stream (which was
            // flowing) just went silent. That's the moment to auto-wake.
            // EXPERIMENTAL, opt-in (WT_DEMOTION_WAKE=1). Detects the stuck state
            // by the pen being demoted to a plain mouse over SAI's window, then
            // auto-bounces. Recovery is solid now (the DLL restores Win32
            // foreground from SAI's UI thread on every bumpWin32Wake), but this
            // TRIGGER can false-fire on intentional trackpad use over SAI's
            // window, so it stays opt-in. The default triggers (app-switch
            // return, dead click) cover the common paths. See issue #2.
            if g_demotionWake, g_penEverSeen,
               CFAbsoluteTimeGetCurrent() - g_lastTabletEvAt > 0.35,
               !g_saiWindow.isEmpty, g_saiWindow.contains(event.location) {
                DispatchQueue.main.async { g_onStuckDetected?() }
            }
        }
    default:
        // Gesture events have no CGEventType case, so they're matched by raw
        // value: 29 = NSEventTypeGesture, 30 = NSEventTypeMagnify. Both are
        // subscribed because trackpads deliver pinch as either depending on the
        // device; the NSEvent type is what actually decides. Listen-only, like
        // the wake hotkey — nothing is consumed.
        if type.rawValue == 29 || type.rawValue == 30 {
            if let ns = NSEvent(cgEvent: event), ns.type == .magnify {
                noteMagnify(ns.magnification)
            }
        }
    }
    return Unmanaged.passUnretained(event)
}

// NOTE: Cmd->Ctrl shortcut remapping (undo/redo/save/etc.) is handled by WINE
// ITSELF, not this helper. ensureSetup() writes LeftCommandIsCtrl/RightCommandIsCtrl
// into the prefix's "Mac Driver" registry, so winemac.drv maps Command->Control
// only inside Wine apps, at the driver level. That's cleaner than synthesizing
// keyboard events (which produced wrong shortcuts — SAI saw a bare key, not
// Ctrl+key) AND it needs NO Accessibility permission. Cmd+Tab / Cmd+Q etc. still
// behave as normal macOS shortcuts. See the project's issue #5 / #7.

// virtual-desktop bounds now + on every display change (monitor plug/unplug)
refreshVirtualBounds()
let reconfigCB: CGDisplayReconfigurationCallBack = { _, _, _ in refreshVirtualBounds() }
CGDisplayRegisterReconfigurationCallback(reconfigCB, nil)

// ---- the pressure engine: create the taps + timers on the current run loop.
// Prevent App Nap. While SAI is frontmost our helper is in the background, and
// macOS throttles background apps — which stalls our run loop and puts the event
// tap to sleep, so pen samples stop arriving (recv freezes, no brush dot, canvas
// "stuck"). Holding a user-initiated activity for the whole session stops that.
var g_noNap: NSObjectProtocol?

// Returns false if the tablet tap can't be created (permission missing). ------
func startPressureEngine() -> Bool {
    if g_noNap == nil {
        g_noNap = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Streaming live tablet pressure to SAI")
    }
    // Built up in a loop rather than as one big `|` chain: at nine terms Swift's
    // type checker gave up with "unable to type-check this expression in
    // reasonable time" on CI (it squeaked through locally on a different
    // compiler version, which is exactly the sort of difference CI is for).
    var mask: CGEventMask = 0
    for t in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved,
              .tabletPointer, .tabletProximity,
              .keyDown] {                                   // keyDown = wake hotkey
        mask |= CGEventMask(1) << t.rawValue
    }
    // Gesture types have no CGEventType case: 29 = NSEventTypeGesture,
    // 30 = NSEventTypeMagnify (pinch to zoom, issue #22).
    mask |= CGEventMask(1) << 29
    mask |= CGEventMask(1) << 30
    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
    gTap = tap
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    let kaTimer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.04, 0.04, 0, 0) { _ in keepAlive() }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), kaTimer, .commonModes)

    // Keep SAI's menu-strip rect fresh (window moves/resizes) — see emit().
    if menuStripH > 0 {
        refreshSAIStrip()
        let stripTimer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1.0, 1.0, 0, 0) { _ in refreshSAIStrip() }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), stripTimer, .commonModes)
    }

    writeFile("0")                      // start pen-up
    return true
}

// Start the engine at most once. The wizard can start it early (the "Test
// Tablet Pressure" button) AND on Launch; creating the tap twice would be wrong.
var engineStarted = false
func startPressureEngineOnce() -> Bool {
    if engineStarted { return true }
    if startPressureEngine() { engineStarted = true }
    return engineStarted
}

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
    _ = osa("tell application \"Terminal\" to do script \"bash '\(sh)'\"")
    _ = osa("tell application \"Terminal\" to activate")
}
func saiReady() -> Bool { savedSAIPath() != nil }

// ============================================================================
//  ENTRY POINT
// ============================================================================
if !isAppMode {
    // Dev / terminal mode: start the engine right away and run.
    if !startPressureEngine() {
        print("ERROR: tap failed — grant this terminal Input Monitoring, then re-run.")
        exit(1)
    }
    signal(SIGINT) { _ in try? "0".write(toFile: outPath, atomically: true, encoding: .ascii); exit(0) }
    print("wacom-pressure-helper running — writing to \(outPath). Ctrl+C to quit.")
    CFRunLoopRun()
}

// A dead-simple pressure bar we draw ourselves. NSProgressIndicator eases
// (animates) toward each new value, which lags behind the real pen pressure and
// feels "smoothed". This redraws INSTANTLY on every value set, so the bar tracks
// the pen exactly like the % number does.
final class PressureBar: NSView {
    var value: CGFloat = 0 { didSet { if value != oldValue { needsDisplay = true } } }  // 0...1
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds, radius = r.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        let v = min(1, max(0, value))
        if v > 0.001 {
            let w = max(r.height, r.width * v)                 // keep a round cap even when tiny
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: r.height),
                         xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// Live plot of the pen-feel curve: input pressure across, output up. The
/// diagonal is linear (gamma 1); the dot is where the pen is right now, so you
/// can press and watch the mapping instead of interpreting a number.
/// Draw-here area for the pen test. The pressure bar proves a signal arrives;
/// this proves it FEELS right — taper at the ends of a stroke is the thing
/// people actually care about, and a number cannot show it.
///
/// Pressure comes from the event when macOS provides it, falling back to the
/// value our own tablet tap last saw, so it still works for input paths that
/// report no NSEvent pressure.
final class PenScratchView: NSView {
    private typealias Point = (p: CGPoint, w: CGFloat)
    private struct Stroke { var pts: [Point]; var finished: Date? }

    private var strokes: [Stroke] = []
    private var current: [Point] = []
    private var fade: Timer?

    /// How long a finished stroke stays solid, then how long it takes to vanish.
    /// Long enough to judge the taper, short enough that the pad is clean again
    /// by the time you come back to it — so there is nothing to press to reset.
    private let holdSeconds: TimeInterval = 2.0
    private let fadeSeconds: TimeInterval = 2.0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func clear() { strokes.removeAll(); current.removeAll(); stopFade(); needsDisplay = true }

    private func alpha(_ s: Stroke) -> CGFloat {
        guard let f = s.finished else { return 1 }              // still drawing
        let age = Date().timeIntervalSince(f) - holdSeconds
        if age <= 0 { return 1 }
        return max(0, 1 - CGFloat(age / fadeSeconds))
    }

    private func startFade() {
        guard fade == nil else { return }
        // 20fps is plenty for a fade and costs nothing; it stops itself as soon
        // as the pad is empty, so an idle window does no work at all.
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.strokes.removeAll { self.alpha($0) <= 0 }
            self.needsDisplay = true
            if self.strokes.isEmpty && self.current.isEmpty { self.stopFade() }
        }
        RunLoop.main.add(t, forMode: .common)
        fade = t
    }
    private func stopFade() { fade?.invalidate(); fade = nil }

    /// Runs the same pipeline the helper uses before sending a value to SAI, so
    /// the pad shows what the settings above it actually do rather than a
    /// prettier approximation of it.
    private func width(for e: NSEvent) -> CGFloat {
        // 1. raw 0…1. NSEvent carries pressure for tablet input; fall back to
        //    whatever our own tap last saw for paths that report none.
        var p = Double(e.pressure)
        if p <= 0 { p = Double(max(0, lastKeyP)) / Double(max(1, PressureCore.maxPressure)) }
        p = min(1, max(0, p))

        // 2. quantise to the configured level count, so picking 1024 against
        //    8192 is visible as steppier width rather than being invisible.
        let levels = Double(max(1, PressureCore.maxPressure))
        p = (p * levels).rounded() / levels

        // 3. pen feel and the feel curve are the same knob — both write
        //    PressureCore.pressureGamma — so one call covers both.
        p = PressureCore.curved(p)

        return 1 + CGFloat(p) * 22     // tapered without becoming a blob
    }

    override func mouseDown(with e: NSEvent) {
        current = [(convert(e.locationInWindow, from: nil), width(for: e))]
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        current.append((convert(e.locationInWindow, from: nil), width(for: e)))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        if current.count > 1 { strokes.append(Stroke(pts: current, finished: Date())) }
        current.removeAll()
        startFade()
        needsDisplay = true
    }

    override func draw(_ r: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill(); r.fill()
        NSColor.separatorColor.setStroke()
        frame.stroke()
        // Ink must stay inside the box. A drag continues to deliver points once
        // the pointer leaves the view, which is correct for tracking but must
        // not paint over the rest of the window.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        frame.setClip()

        if strokes.isEmpty && current.isEmpty {
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor]
            let t = "Draw here with your pen — strokes taper with pressure, then fade"
            let sz = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                               y: (bounds.height - sz.height) / 2), withAttributes: a)
            return
        }

        var all = strokes
        if current.count > 1 { all.append(Stroke(pts: current, finished: nil)) }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for stroke in all {
            // A stroke is drawn as many round-capped segments, because its width
            // varies along its length and one path carries only one line width.
            // Fading them individually made every overlap blend twice, so the
            // line dissolved into a string of beads. A transparency layer
            // composites the whole stroke once, at one alpha, so it fades as a
            // single line.
            ctx.saveGState()
            ctx.setAlpha(alpha(stroke))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.labelColor.setStroke()
            for i in 1..<stroke.pts.count {
                let seg = NSBezierPath()
                seg.move(to: stroke.pts[i - 1].p)
                seg.line(to: stroke.pts[i].p)
                seg.lineWidth = (stroke.pts[i - 1].w + stroke.pts[i].w) / 2
                seg.lineCapStyle = .round
                seg.stroke()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }
}

final class GammaCurveView: NSView {
    var gamma: Double = 1.0 { didSet { if gamma != oldValue { needsDisplay = true } } }
    var live: Double = 0 { didSet { if live != oldValue { needsDisplay = true } } }   // 0...1 input

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

        // linear reference
        NSColor.tertiaryLabelColor.setStroke()
        let diag = NSBezierPath()
        diag.move(to: NSPoint(x: r.minX, y: r.minY))
        diag.line(to: NSPoint(x: r.maxX, y: r.maxY))
        diag.lineWidth = 1
        diag.setLineDash([3, 3], count: 2, phase: 0)
        diag.stroke()

        // the actual curve
        let curve = NSBezierPath()
        curve.lineWidth = 2
        for i in 0...60 {
            let x = Double(i) / 60.0
            let y = gamma == 1.0 ? x : pow(x, gamma)
            let p = NSPoint(x: r.minX + CGFloat(x) * r.width, y: r.minY + CGFloat(y) * r.height)
            if i == 0 { curve.move(to: p) } else { curve.line(to: p) }
        }
        NSColor.controlAccentColor.setStroke()
        curve.stroke()

        // where the pen is right now
        if live > 0.001 {
            let y = gamma == 1.0 ? live : pow(live, gamma)
            let p = NSPoint(x: r.minX + CGFloat(live) * r.width, y: r.minY + CGFloat(y) * r.height)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
    }
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
    var curveView: GammaCurveView!
    let feelChoices: [(String, Double)] = [("Very soft", 0.55), ("Soft", 0.75), ("Normal", 1.0), ("Firm", 1.35), ("Very firm", 1.8)]        // highest raw level seen this test run

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
    var libStore: LibraryStore?
    var settingsTab: NSStackView!
    var settingsScratch: PenScratchView!
    var scratchRow: NSStackView!
    var autoWakeCheck: NSButton!
    var recUsageLabel: NSTextField!
    var recPreview: AVPlayerView!
    var recPreviewLabel: NSTextField!
    var recHidePreviewBtn: NSButton!
    var devCheck: NSButton!
    var console: NSTextView!
    var consoleScroll: NSScrollView!
    let rowWidth: CGFloat = 500

    func lbl(_ s: String, _ size: CGFloat, bold: Bool = false, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        l.textColor = color
        return l
    }

    func applicationDidFinishLaunching(_ note: Notification) {
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
            Req(title: "PaintTool SAI folder (source)", detail: "No folder chosen yet — click Choose.", fixTitle: "Choose…",
                ok: { saiReady() }, fix: { [weak self] in self?.chooseSAI() }, required: true,
                dynamicDetail: { savedSAIPath().map { "Copied from: \(($0 as NSString).abbreviatingWithTildeInPath)" }
                                 ?? "No folder chosen yet — click Choose." },
                keepButton: true),
            Req(title: "Installed in Wine (what actually runs)", detail: "Not installed yet.", fixTitle: "Install…",
                ok: { saiInstalledInPrefix() && !prefixIsStale() },
                fix: { [weak self] in self?.reinstallMenu() }, required: true,
                dynamicDetail: {
                    let where_ = (prefixSAIDir as NSString).abbreviatingWithTildeInPath
                    if !saiInstalledInPrefix() { return "Not installed yet — will be created on Launch." }
                    if prefixIsStale() { return "OUT OF DATE — source folder changed. Reinstall to apply." }
                    // Read from SAI's own history.txt, so it survives renamed folders.
                    return saiBuildLabel().map { "\(where_)  ·  \($0)" } ?? where_
                },
                keepButton: true, keepButtonTitle: "Reinstall…",
                enabledIf: { wineBin() != nil && saiReady() },
                blockedHint: "Needs Wine and a SAI folder first — SAI is installed INTO the Wine prefix.",
                extraTitle: "Show ▸", extraAction: { [weak self] in self?.openSAIInWine() }),
            // Optional (⚪️ not ❌): SAI launches without a licence, you just
            // can't save. Lives next to the INSTALLED row because that's the
            // folder it has to land in.
            // OPTIONAL, and deliberately not a blocker: SAI installs, launches and
            // draws without a licence — it just can't save. Marked ⚪️, never ❌.
            Req(title: "SAI license (.slc) — optional", detail: "Your own license from SYSTEMAX — only needed to save.", fixTitle: "Install…",
                ok: { installedLicenseName() != nil },
                fix: { [weak self] in self?.chooseLicense() }, required: false,
                dynamicDetail: {
                    if let n = installedLicenseName() { return "\(n) — \(licenseLocationSummary())" }
                    if !slcFiles(in: licenseStashDir()).isEmpty {
                        return "Saved copy will be restored when SAI is installed."
                    }
                    return "Not installed — SAI still runs and draws, but can't save."
                },
                keepButton: true,
                extraTitle: "Show ▸", extraAction: { [weak self] in self?.revealLicense() }),
            Req(title: "Input Monitoring permission", detail: "lets the app read your tablet's pressure", fixTitle: "Grant…",
                ok: { inputMonitoringGranted() }, fix: { [weak self] in self?.grantInputMonitoring() }, required: true,
                extraTitle: "Ask again", extraAction: { [weak self] in self?.resetOwnPermission() },
                extraWhenSatisfied: false),
        ]
        buildWindow()
        refresh()
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

    // Find the running Wine/SAI app (the process SAI runs inside).
    func wineRunningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            let hay = "\(app.bundleIdentifier ?? "") \(app.localizedName ?? "") \(app.executableURL?.path ?? "")".lowercased()
            return hay.contains("wine") || hay.contains("sai")
        }
    }

    // Force SAI's window fully active again. Hiding then re-activating the app is
    // a full activation cycle — the strongest, permission-free equivalent of the
    // Space-swipe — so a "stuck"/greyed window becomes key and takes clicks again.
    // Find the process that owns SAI's biggest ON-SCREEN window. Wine runs as
    // several processes; only one owns the visible window we need to wake.
    // CGWindowList gives owner name/pid/bounds with NO permission (only window
    // TITLES need screen-recording, which we don't read).
    func saiWindowOwnerPID() -> pid_t {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var bestPid: pid_t = 0, bestArea = -1
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            guard owner.contains("wine") || owner.contains("sai") else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let area = Int((b["Width"] ?? 0) * (b["Height"] ?? 0))
            let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
            wlog("  win owner=\(owner) pid=\(pid) layer=\(layer) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))")
            if layer == 0 && area > bestArea { bestArea = area; bestPid = pid_t(pid) }
        }
        return bestPid
    }

    @objc func wakeSAI() {
        wlog("wakeSAI called")
        bumpWin32Wake()
        let ownerPid = saiWindowOwnerPID()
        wlog("  SAI window owner pid=\(ownerPid)")
        let app = (ownerPid != 0 ? NSRunningApplication(processIdentifier: ownerPid) : nil) ?? wineRunningApp()
        guard let app = app else { wlog("  -> NO app to target"); NSSound.beep(); return }
        // GENTLE by default: just re-activate the CORRECT window-owning process —
        // no hide. Hiding the whole app un-sticks the window but resets SAI's pen
        // state (OS arrow everywhere, can't draw until you repeat it). WT_WAKE_HIDE=1
        // forces the old heavy hide+reactivate if the gentle path isn't enough.
        if ProcessInfo.processInfo.environment["WT_WAKE_HIDE"] != nil {
            wlog("  -> hide+reactivate pid=\(app.processIdentifier)")
            app.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                app.unhide(); app.activate(options: [.activateAllWindows])
            }
        } else {
            wlog("  -> gentle activate pid=\(app.processIdentifier)")
            app.activate(options: [.activateAllWindows])
        }
        // post-transition wake, once macOS has settled (see bounceToSAI)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            wlog("  -> post-wakeSAI wake bump")
            self.bumpWin32Wake()
        }
    }

    // AUTO-WAKE (issue #2): whenever Wine/SAI comes to the front, re-activate the
    // process that actually OWNS SAI's on-screen window.
    // Why this used to fail: Wine runs as several processes. The activation
    // notification hands us the *registered* wine app (e.g. pid 40099), but the
    // visible window belongs to a different pid (e.g. 40101). Activating the
    // notified one does nothing — which is exactly why the manual button (which
    // resolves the owner via CGWindowList) works and the old auto path didn't.
    // Toggle live from the 🖊 menu; WT_NO_AUTOWAKE=1 starts it off.
    var autoWake = ProcessInfo.processInfo.environment["WT_NO_AUTOWAKE"] == nil
    var bouncing = false          // true while WE are re-activating (ignore our own events)
    var lastReactivate = Date.distantPast
    @objc func appActivated(_ note: Notification) {
        guard autoWake, !bouncing,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let hay = "\(app.bundleIdentifier ?? "") \(app.localizedName ?? "") \(app.executableURL?.path ?? "")".lowercased()
        guard hay.contains("wine") || hay.contains("sai") else { return }
        guard Date().timeIntervalSince(lastReactivate) > 0.6 else { return }   // no feedback loop
        lastReactivate = Date()
        // Let macOS finish its own activation first, then nudge the real owner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, self.autoWake else { return }
            let owner = self.saiWindowOwnerPID()
            guard owner != 0, let target = NSRunningApplication(processIdentifier: owner) else { return }
            wlog("autoWake(activate): notified pid=\(app.processIdentifier) windowOwner pid=\(owner)")
            self.bounceToSAI(target)
        }
    }

    // THE BOUNCE. Plain activate() is a no-op when macOS already thinks Wine is
    // frontmost, so the window stays stuck. The manual menu-bar button only works
    // because clicking the menu bar makes THIS app active first, making the
    // following activate() a real transition. So do that deliberately: take
    // activation for a moment, then hand it straight back to the window's real
    // owner. Our own window is minimized while you draw, so it's a brief blink.
    // Ask our DLL (which runs INSIDE SAI) to restore SAI's Win32 foreground/active
    // window. macOS-side activation alone doesn't do it: Wine can leave the Win32
    // state stale, and SAI then eats every canvas click (MA_NOACTIVATEANDEAT) so
    // the canvas is dead to pen AND mouse while the menu bar still works.
    var wakeSeq = 0
    func bumpWin32Wake() {
        wakeSeq += 1
        try? "\(wakeSeq)".write(toFile: "\(appPrefix)/drive_c/wt_wake.txt", atomically: true, encoding: .ascii)
    }

    func bounceToSAI(_ target: NSRunningApplication) {
        bouncing = true
        bumpWin32Wake()
        // Step 1: take activation AWAY from SAI. Prefer bouncing off ANOTHER Wine
        // process — Wine runs several, and switching between two of them keeps the
        // menu bar showing "Wine", so the bounce is invisible. Falling back to our
        // own app works too but blinks the menu bar.
        if let other = wineRunningApp(), other.processIdentifier != target.processIdentifier {
            wlog("  bounce via wine pid=\(other.processIdentifier)")
            other.activate(options: [])
        } else {
            wlog("  bounce via self (no second wine process)")
            NSApp.activate(ignoringOtherApps: true)
        }
        // Step 2: hand activation back to the process that owns SAI's window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            target.activate(options: [.activateAllWindows])
            wlog("  -> re-activated owner pid=\(target.processIdentifier)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.bouncing = false }
            // Bump AGAIN once the transition has settled: the bump at bounce
            // start can fire the DLL's wake MID-bounce (while the OTHER wine
            // process is still the active Cocoa app), and winemac.drv ignores
            // key-window changes for an inactive app — a wasted wake. This one
            // runs with SAI properly active, so the driver-level focus refresh
            // actually takes. See issue #2.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                wlog("  -> post-bounce wake bump")
                self.bumpWin32Wake()
            }
        }
    }

    // Auto-wake trigger #2: a click inside SAI's window. Fires ONLY when you
    // haven't drawn for a few seconds — if pressure is flowing, SAI is obviously
    // not stuck, so we never bounce mid-drawing. Covers the case the activation
    // notification can't: SAI already frontmost, stuck, and you click it again.
    func autoWakeOnClick(at loc: CGPoint) {
        guard autoWake, !bouncing else { return }
        // Don't touch clicks on the menu strip — a bounce there would dismiss the
        // menu the click just opened.
        if !g_saiStrip.isEmpty && g_saiStrip.contains(loc) { return }
        // Look at the result of the click a moment LATER. If it produced drawing,
        // SAI is obviously alive -> do nothing. If nothing happened and Wine is
        // (still) frontmost, that was a dead click -> un-stick it. This also
        // covers clicking Wine's "exec" Dock tile, which fires no activation
        // notification when Wine is already frontmost.
        let insideSAI = !g_saiWindow.isEmpty && g_saiWindow.contains(loc)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.autoWake, !self.bouncing else { return }
            let now = Date()
            guard now.timeIntervalSince(g_lastDrawAt) > 1.0,      // nothing was drawn by that click
                  now.timeIntervalSince(self.lastReactivate) > 2.0,
                  let front = NSWorkspace.shared.frontmostApplication,
                  let target = self.saiTarget() else { return }
            let hay = "\(front.bundleIdentifier ?? "") \(front.localizedName ?? "") \(front.executableURL?.path ?? "")".lowercased()
            let frontIsSAI = hay.contains("wine") || hay.contains("sai")
            if frontIsSAI {
                // On SAI, but the click drew nothing -> dead click, un-stick it.
                self.lastReactivate = now
                wlog("autoWake(click/dead): front=\(front.processIdentifier) owner=\(target.processIdentifier)")
                self.bounceToSAI(target)
            } else if insideSAI {
                // Clicked SAI's window but another app is STILL frontmost — the
                // click didn't even raise it (SAI behind another window). Coming
                // from a different app is already a real transition, so a plain
                // activate is enough; no bounce needed.
                self.lastReactivate = now
                wlog("autoWake(click/raise): front=\(front.localizedName ?? "?") -> owner=\(target.processIdentifier)")
                self.bumpWin32Wake()
                target.activate(options: [.activateAllWindows])
                // post-transition wake, once macOS has settled (see bounceToSAI)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    wlog("autoWake(click/raise): post bump")
                    self.bumpWin32Wake()
                }
            }
        }
    }

    @objc func toggleAutoWake(_ sender: NSMenuItem) {
        autoWake.toggle()
        sender.state = autoWake ? .on : .off
    }

    // Fired when the tap detects the pen was demoted to a plain mouse (the real
    // "SAI stuck" signature). Un-stick it — same bounce the button uses.
    func autoWakeStuck() {
        guard autoWake, !bouncing,
              Date().timeIntervalSince(lastReactivate) > 1.5,
              let target = saiTarget() else { return }
        lastReactivate = Date()
        wlog("autoWake(demotion): owner pid=\(target.processIdentifier)")
        bounceToSAI(target)
    }

    var statusItem: NSStatusItem?




    @objc func reinstallTapped() { showSetupWindow(); reinstallMenu() }
    @objc func licenseTapped()   { showSetupWindow(); chooseLicense() }




    func applicationDidBecomeActive(_ note: Notification) { refresh() }   // re-check when refocused

    // ---- version / update check -----------------------------------------------
    var versionLabel: NSTextField!
    var updateLabel: NSTextField!
    var updateBtn: NSButton!
    var latestTag: String?
    var latestNotes: String = ""
    let repoSlug = "ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix"






    // The process that owns SAI's on-screen window (see saiWindowOwnerPID).
    func saiTarget() -> NSRunningApplication? {
        let owner = saiWindowOwnerPID()
        return owner != 0 ? NSRunningApplication(processIdentifier: owner) : nil
    }

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

    func buildWindow() {
        // NOTE: assigns the PROPERTY, not a local — applyLayout() needs it later
        // to measure fittingSize. A `let content = …` here shadows the property
        // and leaves self.content nil.
        content = NSStackView()
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(lbl("SAI Pen Pressure Setup", 18, bold: true))
        subtitle = lbl("Let's get everything ready.", 12, color: .secondaryLabelColor)
        content.addArrangedSubview(subtitle)

        for (i, r) in reqs.enumerated() {
            let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
            let status = lbl("…", 13, bold: true)
            status.widthAnchor.constraint(equalToConstant: 18).isActive = true
            statusFields.append(status)
            let col = NSStackView(); col.orientation = .vertical; col.alignment = .leading; col.spacing = 0
            col.addArrangedSubview(lbl(r.title, 12, bold: true))
            let detail = lbl(r.detail, 10, color: .secondaryLabelColor)
            detailFields.append(detail)
            col.addArrangedSubview(detail)
            let btn = NSButton(title: r.fixTitle, target: self, action: #selector(fixTapped(_:)))
            btn.tag = i; btn.bezelStyle = .rounded; btn.controlSize = .small
            btn.setContentHuggingPriority(.required, for: .horizontal)
            fixButtons.append(btn)
            let spacer = NSView()
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
            row.addArrangedSubview(status); row.addArrangedSubview(col); row.addArrangedSubview(spacer)
            // "Show ▸" sits before the main action so the primary button stays
            // in the same column down the whole checklist.
            if r.extraTitle != nil {
                let extra = NSButton(title: r.extraTitle!, target: self, action: #selector(extraTapped(_:)))
                extra.tag = i; extra.bezelStyle = .rounded; extra.controlSize = .small
                extra.setContentHuggingPriority(.required, for: .horizontal)
                extraButtons.append(extra)
                row.addArrangedSubview(extra)
            } else {
                extraButtons.append(nil)
            }
            row.addArrangedSubview(btn)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            rowViews.append(row)
            content.addArrangedSubview(row)
        }

        // --- "all set" summary -------------------------------------------------
        // Simple mode hides satisfied rows, so a finished setup left a blank gap
        // above Launch. Replace it with a compact green confirmation of exactly
        // what's ready, so the space reads as reassurance rather than absence.
        allSetLabel = lbl("", 11, color: .secondaryLabelColor)
        content.addArrangedSubview(allSetLabel)

        // --- automatic setup: the one button that does the whole checklist ----
        autoBtn = NSButton(title: "Set up everything automatically", target: self, action: #selector(autoSetup))
        autoBtn.bezelStyle = .rounded; autoBtn.controlSize = .large
        content.addArrangedSubview(autoBtn)

        // Live Wine download progress, piped from install-wine.sh's curl.
        wineRow = NSStackView(); wineRow.orientation = .horizontal
        wineRow.alignment = .centerY; wineRow.spacing = 10
        wineBar = PressureBar()
        wineBar.widthAnchor.constraint(equalToConstant: 200).isActive = true
        wineBar.heightAnchor.constraint(equalToConstant: 12).isActive = true
        wineLabel = lbl("", 11, color: .secondaryLabelColor)
        wineRow.addArrangedSubview(wineBar); wineRow.addArrangedSubview(wineLabel)
        wineRow.isHidden = true
        content.addArrangedSubview(wineRow)

        // --- primary action ---------------------------------------------------
        launchBtn = NSButton(title: "Launch SAI with Pressure", target: self, action: #selector(launchTapped))
        launchBtn.bezelStyle = .rounded; launchBtn.keyEquivalent = "\r"; launchBtn.controlSize = .large
        content.addArrangedSubview(launchBtn)

        // --- secondary actions, side by side instead of stacked ---------------
        let wakeBtn = NSButton(title: "Wake SAI (if stuck)", target: self, action: #selector(wakeSAI))
        wakeBtn.bezelStyle = .rounded; wakeBtn.controlSize = .small
        advancedBtn = NSButton(title: "Show all steps ⌄", target: self, action: #selector(toggleAdvanced))
        advancedBtn.bezelStyle = .rounded; advancedBtn.controlSize = .small
        secondaryRow = NSStackView(); secondaryRow.orientation = .horizontal
        secondaryRow.alignment = .centerY; secondaryRow.spacing = 8
        secondaryRow.addArrangedSubview(wakeBtn)
        autoWakeCheck = NSButton(checkboxWithTitle: "Auto-wake", target: self,
                                 action: #selector(autoWakeCheckToggled))
        autoWakeCheck.controlSize = .small
        secondaryRow.addArrangedSubview(autoWakeCheck)
        secondaryRow.addArrangedSubview(advancedBtn)
        content.addArrangedSubview(secondaryRow)

        testHint = lbl("Press your pen on the tablet — the bar should move.", 10, color: .secondaryLabelColor)
        testHint.preferredMaxLayoutWidth = rowWidth
        testHint.isHidden = true
        barRow = NSStackView(); barRow.orientation = .horizontal; barRow.alignment = .centerY; barRow.spacing = 10
        pressureBar = PressureBar()
        pressureBar.widthAnchor.constraint(equalToConstant: 240).isActive = true
        pressureBar.heightAnchor.constraint(equalToConstant: 12).isActive = true
        // Show the RAW value and the scale, not just a percent — the whole point
        // of issue #21 is how many distinct levels actually arrive, and a
        // percentage hides that completely.
        pressureLabel = lbl("0 / \(PressureCore.maxPressure)", 11, bold: true)
        pressureLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        barRow.addArrangedSubview(pressureBar); barRow.addArrangedSubview(pressureLabel)
        barRow.isHidden = true


        // --- pressure resolution, in Settings ---------------------------------
        // Auto follows the tablet's own HID report; the explicit choices are an
        // override for people who want to experiment. Above the tablet's real
        // count you get noise, not detail, so the UI says so.
        let pRow = NSStackView(); pRow.orientation = .horizontal; pRow.spacing = 8
        pRow.alignment = .centerY
        pRow.addArrangedSubview(lbl("Pressure levels", 12, bold: true))
        pressurePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        settingsTab = NSStackView()
        settingsTab.orientation = .vertical; settingsTab.alignment = .leading; settingsTab.spacing = 10
        settingsTab.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        settingsTab.addArrangedSubview(lbl("Pen settings", 18, bold: true))
        // Defended explicitly: a stack short of room compresses by this
        // priority, and the default let real controls collapse silently.
        defer {
            settingsTab.arrangedSubviews.forEach {
                if !($0 is PenScratchView) {
                    $0.setContentCompressionResistancePriority(.required, for: .vertical)
                }
            }
        }

        pressurePopup.controlSize = .small
        pressurePopup.target = self
        pressurePopup.action = #selector(pressureChoiceChanged)
        pressurePopup.addItem(withTitle: "Auto")
        for v in PressureCore.pressureChoices { pressurePopup.addItem(withTitle: "\(v + 1)") }
        pRow.addArrangedSubview(pressurePopup)
        pressureInfo = lbl("", 10, color: .tertiaryLabelColor)
        pRow.addArrangedSubview(pressureInfo)
        settingsTab.addArrangedSubview(pRow)

        // Pen feel: applied on our side before the value is sent, so it needs no
        // agreement with the DLL and no SAI restart. Stacks with the Wacom
        // driver's own curve and SAI's per-brush Min Size — hence Normal default.
        let fRow = NSStackView(); fRow.orientation = .horizontal; fRow.spacing = 8
        fRow.alignment = .centerY
        fRow.addArrangedSubview(lbl("Pen feel", 12, bold: true))
        feelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        feelPopup.controlSize = .small
        feelPopup.target = self; feelPopup.action = #selector(feelChanged)
        for (name, _) in feelChoices { feelPopup.addItem(withTitle: name) }
        fRow.addArrangedSubview(feelPopup)
        fRow.addArrangedSubview(lbl("how hard you press for a full-width stroke · applies instantly", 10, color: .tertiaryLabelColor))
        settingsTab.addArrangedSubview(fRow)

        // --- one-button recovery, in Settings ---------------------------------
        // The whole point: a single obvious action that rebuilds everything, for
        // when the prefix is broken and you don't want to reason about which
        // half is at fault.
        scratchRow = NSStackView(); scratchRow.orientation = .horizontal; scratchRow.spacing = 8
        let scratchBtn = NSButton(title: "Reset everything & reinstall…", target: self, action: #selector(installFromScratch))
        scratchBtn.bezelStyle = .rounded; scratchBtn.controlSize = .small
        scratchRow.addArrangedSubview(scratchBtn)
        let uninstallBtn = NSButton(title: "Uninstall…", target: self, action: #selector(uninstallEverything))
        uninstallBtn.bezelStyle = .rounded; uninstallBtn.controlSize = .small
        scratchRow.addArrangedSubview(uninstallBtn)
        let scratchHint = lbl("Your SAI folder and license are kept.", 10, color: .tertiaryLabelColor)
        scratchRow.addArrangedSubview(scratchHint)
        // NOT appended to rowViews — that array is index-locked to `reqs` and an
        // extra entry would desync applyLayout()'s loop. It's Settings-only.
        // --- footers: explanation, only in Settings ---------------------------
        // Kept to ONE line each — these wrapped to two and made the window tall.
        for s in ["Wake: menu-bar pen icon, Dock right-click, or ⌃⌥⌘Space.",
                  "SAI runs from a copy in \(( appPrefix as NSString).abbreviatingWithTildeInPath); the source folder is only needed to (re)install.",
                  "PaintTool SAI © SYSTEMAX — unaffiliated fix, bring your own license (systemax.jp)."] {
            let l = lbl(s, 10, color: .tertiaryLabelColor)
            l.preferredMaxLayoutWidth = rowWidth
            l.lineBreakMode = .byWordWrapping
            l.usesSingleLineMode = false
            footerLabels.append(l)
            content.addArrangedSubview(l)
        }

        // --- developer section (inside Settings) ------------------------------
        devSection = NSStackView(); devSection.orientation = .vertical
        devSection.alignment = .leading; devSection.spacing = 6
        devCheck = NSButton(checkboxWithTitle: "Developer mode", target: self, action: #selector(toggleDevCheck))
        devSection.addArrangedSubview(devCheck)
        // Folders first — "where did my SAI actually go?" is the question the
        // whole copy-into-the-prefix model raises, so answer it with a button.
        let devFolders = NSStackView(); devFolders.orientation = .horizontal; devFolders.spacing = 6
        for (t, s) in [("SAI in Wine ▸", #selector(openSAIInWine)),
                       ("License ▸", #selector(revealLicense)),
                       ("Wine prefix ▸", #selector(openWinePrefix)),
                       ("App data ▸", #selector(openAppSupport))] {
            let b = NSButton(title: t, target: self, action: s)
            b.bezelStyle = .rounded; b.controlSize = .small
            devFolders.addArrangedSubview(b)
        }
        devSection.addArrangedSubview(devFolders)
        let devBtns = NSStackView(); devBtns.orientation = .horizontal; devBtns.spacing = 6
        for (t, s) in [("Diagnostics", #selector(copyDiagnostics)),
                       ("Helper log", #selector(openHelperLog)),
                       ("Wake log", #selector(openWakeLog)),
                       ("DLL log", #selector(openDLLLog))] {
            let b = NSButton(title: t, target: self, action: s)
            b.bezelStyle = .rounded; b.controlSize = .small
            devBtns.addArrangedSubview(b)
        }
        devSection.addArrangedSubview(devBtns)
        let devTools = NSStackView(); devTools.orientation = .horizontal; devTools.spacing = 6
        recBtn = NSButton(title: "● Record session", target: self, action: #selector(toggleRecord))
        recBtn.bezelStyle = .rounded; recBtn.controlSize = .small
        devTools.addArrangedSubview(recBtn)
        let hc = NSButton(title: "Health check", target: self, action: #selector(healthCheckTapped))
        hc.bezelStyle = .rounded; hc.controlSize = .small
        devTools.addArrangedSubview(hc)
        devSection.addArrangedSubview(devTools)

        // Pen feel, precisely: the dropdown picks five presets, this exposes the
        // gamma itself with a live plot. Press the pen while the test is running
        // and the dot tracks the mapping, which beats reasoning about a number.
        let gRow = NSStackView(); gRow.orientation = .horizontal; gRow.spacing = 8
        gRow.alignment = .centerY
        gRow.addArrangedSubview(lbl("Pen feel curve", 11, bold: true))
        gammaSlider = NSSlider(value: PressureCore.pressureGamma, minValue: 0.40, maxValue: 2.50,
                               target: self, action: #selector(gammaSliderMoved))
        gammaSlider.controlSize = .small
        gammaSlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        gRow.addArrangedSubview(gammaSlider)
        gammaLabel = lbl("", 11, bold: true)
        gammaLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true
        gRow.addArrangedSubview(gammaLabel)
        curveView = GammaCurveView()
        curveView.widthAnchor.constraint(equalToConstant: 84).isActive = true
        curveView.heightAnchor.constraint(equalToConstant: 46).isActive = true
        gRow.addArrangedSubview(curveView)
        settingsTab.addArrangedSubview(gRow)
        let gHint = lbl("1.00 = exactly what the tablet reports · below = lighter touch goes further · above = press harder", 9, color: .tertiaryLabelColor)
        gHint.preferredMaxLayoutWidth = rowWidth
        settingsTab.addArrangedSubview(gHint)
        testBtn = NSButton(title: "Test pen", target: self, action: #selector(testTapped))
        testBtn.bezelStyle = .rounded; testBtn.controlSize = .small
        settingsTab.addArrangedSubview(testBtn)
        settingsTab.addArrangedSubview(barRow)
        settingsTab.addArrangedSubview(testHint)

        // The scratch pad is NOT here on purpose. It repeatedly cost the pen
        // settings their place on this tab — most recently by absorbing the
        // stack's layout in a way that pushed them out — and the settings
        // matter more than a nice-to-have preview of the pen feel. The
        // PenScratchView class is kept because it works and may find a better
        // home (its own tab, or a sheet), but nothing on this tab uses it.

        // No Clear button: strokes fade on their own, so the pad is always ready.
        // Live console: the tail of the wake log, so you can watch auto-wake and
        // setup decisions without leaving the window.
        consoleScroll = NSScrollView()
        consoleScroll.hasVerticalScroller = true
        consoleScroll.borderType = .bezelBorder
        consoleScroll.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        consoleScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        console = NSTextView()
        console.isEditable = false
        console.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        console.autoresizingMask = [.width]
        consoleScroll.documentView = console
        devSection.addArrangedSubview(consoleScroll)
        // Deliberately NOT added to `content` any more — it lives in its own tab.
        devSection.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        // --- version + update check ------------------------------------------
        let verRow = NSStackView(); verRow.orientation = .horizontal; verRow.alignment = .centerY; verRow.spacing = 8
        versionLabel = lbl("Version \(currentVersion())", 10, color: .tertiaryLabelColor)
        updateLabel = lbl("", 10, color: .secondaryLabelColor)
        // if the label ever gets long again, truncate it with "…" instead of
        // stretching the row / squeezing the button off the window
        updateLabel.lineBreakMode = .byTruncatingTail
        updateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateBtn = NSButton(title: "What's new / Update…", target: self, action: #selector(openReleasePage))
        updateBtn.bezelStyle = .rounded
        updateBtn.controlSize = .small
        updateBtn.isHidden = true
        verRow.addArrangedSubview(versionLabel)
        verRow.addArrangedSubview(updateLabel)
        verRow.addArrangedSubview(updateBtn)
        content.addArrangedSubview(verRow)

        // Reset and Uninstall are installation actions, so they live on Setup
        // with Launch and Wake — not on Pen, which is about how the pen behaves.
        // Inserted after the secondary action row rather than appended, which
        // would strand them below the footers and the version line.
        // SAI Ver.2 is a rolling preview, so swapping in a new build is a
        // routine thing rather than a repair. Given its own action so nobody
        // has to reach for Reinstall and lose their brushes.
        let updateRow = NSStackView(); updateRow.orientation = .horizontal
        updateRow.alignment = .centerY; updateRow.spacing = 8
        let updateBtn2 = NSButton(title: "Update SAI…", target: self, action: #selector(updateSAITapped))
        updateBtn2.bezelStyle = .rounded; updateBtn2.controlSize = .small
        updateRow.addArrangedSubview(updateBtn2)
        updateRow.addArrangedSubview(
            lbl("point at a newer SAI folder · keeps your licence, brushes and preferences",
                10, color: .tertiaryLabelColor))

        if let after = content.arrangedSubviews.firstIndex(of: secondaryRow) {
            content.insertArrangedSubview(updateRow, at: after + 1)
            content.insertArrangedSubview(scratchRow, at: after + 2)
        } else {
            content.addArrangedSubview(updateRow)
            content.addArrangedSubview(scratchRow)
        }

        buildRecordingTab()

        // Three tabs rather than one column. Setup, recording and developer
        // tools are unrelated concerns, and stacking them meant scrolling past
        // all of them to reach any one.
        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        // Recording is about what is happening now; Timelapses is what has
        // accumulated. Keeping them apart matters because the recording status
        // line is the most important text in the window and should not have to
        // compete with a scrolling list.
        for (label, view) in [("Setup", content!),
                              ("Pen", settingsTab!),
                              ("Recording", recordingTab!),
                              ("Videos", buildLibraryTab()),
                              ("Developer", devSection!)] {
            // NSTabViewItem positions its view with the autoresizing mask, not
            // constraints. Leaving translatesAutoresizingMaskIntoConstraints
            // false gave every tab a zero-sized stack: the controls were all
            // there and unhidden, but laid out at (0,0,0,0). The only thing
            // that showed was the scratch pad, which has explicit size
            // constraints — and with a zero-bounds parent, nothing clipped it,
            // so it drew over the whole window.
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.width, .height]
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = view
            tabView.addTabViewItem(item)
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: rowWidth + 48, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SAI Pen Pressure"
        window.contentView = tabView
        // Delegate assigned only now: addTabViewItem() above selects a tab
        // synchronously, and reacting to that before the window exists is what
        // crashed on launch.
        tabView.delegate = self
        window.isReleasedWhenClosed = false
        if let src = ProcessInfo.processInfo.environment["SAIPP_TEST_UPDATE"] {
            let r = updateSAIFromFolder(src)
            try? (r ?? "OK").write(toFile: "/tmp/updresult.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        applyLayout()               // sizes the window to whichever tier is showing
        window.center()
        window.makeKeyAndOrderFront(nil)
    }






    @objc func autoWakeCheckToggled() { autoWake = (autoWakeCheck.state == .on) }


    @objc func clearSettingsScratch() { settingsScratch?.clear() }





    /// Quitting the app ends the recording too. SAI closing is the usual way a
    /// session finishes, but not the only one — and segments left behind look
    /// to anyone reading the folder like nothing was recorded at all.
    func applicationWillTerminate(_ note: Notification) {
        stopLiveEncoder()
        finalizeTimelapseNow()
    }

    func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        refreshRecordingTab()
        if item?.identifier as? String == "Videos" { refreshLibraryTab() }
        // The console only refreshed while the old "Settings" disclosure was
        // open, so in the tabbed layout it showed as an empty black box.
        if item?.identifier as? String == "Developer" { updateConsole() }
        applyLayout()
    }

    @objc func toggleAdvanced() {
        advanced.toggle()
        if !advanced { stopTest() }
        applyLayout()
    }
    @objc func toggleDevCheck() {
        devMode = (devCheck.state == .on)      // persists + rebuilds the menus
        applyLayout()
    }

    /// Show only what the current tier needs, then shrink/grow the window to fit.
    /// Simple mode hides any requirement that's already satisfied — a finished
    /// setup collapses to a title, one status line and the Launch button.
    func applyLayout() {
        // addTabViewItem() selects the first tab immediately, which fires
        // tabView(_:didSelect:) -> applyLayout() while buildWindow() is still
        // running and `window` is nil. Force-unwrapping it there crashed the app
        // on launch. Cheap guard, and it also covers any future early caller.
        guard window != nil else { return }
        for (i, r) in reqs.enumerated() {
            let ok = r.ok()
            rowViews[i].isHidden = advanced ? false : ok
        }
        // In Simple mode a finished setup hides every row, which left a blank
        // gap. Fill it with an explicit green confirmation of what's ready.
        let done = reqs.filter { $0.ok() }.count
        // The automatic path is only worth offering while something is missing.
        let needsWork = reqs.contains { $0.required && !$0.ok() }
        autoBtn.isHidden = !needsWork || autoRunning
        launchBtn.isHidden = needsWork && !autoRunning
        if !advanced && done == reqs.count {
            allSetLabel.stringValue = "✅ Wine · SAI installed · License · Input Monitoring — all ready"
            allSetLabel.isHidden = false
        } else if !advanced && done > 0 {
            allSetLabel.stringValue = "✅ \(done) of \(reqs.count) ready"
            allSetLabel.isHidden = false
        } else {
            allSetLabel.isHidden = true
        }
        footerLabels.forEach { $0.isHidden = !advanced }
        // devSection lives in its own tab now; never hide it wholesale.
        devCheck.state = devMode ? .on : .off
        consoleScroll.isHidden = !devMode
        devSection.arrangedSubviews.forEach { if $0 !== devCheck { $0.isHidden = !devMode } }
        autoWakeCheck?.state = autoWake ? .on : .off
        advancedBtn.title = advanced ? "Show all steps ⌃" : "Show all steps ⌄"
        if devMode && advanced { updateConsole() }
        window.layoutIfNeeded()
        // Measure the tab actually on screen: the tabs differ a lot in height,
        // and sizing to Setup while Developer is showing clips the console.
        let shown = (tabView?.selectedTabViewItem?.view as? NSStackView) ?? content
        let fit = shown!.fittingSize
        // The tab bar and its insets are NOT part of the tab's content area, so
        // sizing the window to the stack's fittingSize alone left the bottom of
        // every tab clipped by roughly the height of the tab strip.
        var chromeW: CGFloat = 0, chromeH: CGFloat = 0
        if let tv = tabView {
            chromeW = max(0, tv.frame.width - tv.contentRect.width)
            chromeH = max(0, tv.frame.height - tv.contentRect.height)
        }
        // A couple of points of slack. Measuring chrome from the current frame
        // is inherently one layout behind, and being even slightly short is not
        // a cosmetic problem — the stack compresses its contents to fit.
        let want = NSSize(width: max(rowWidth + 48, fit.width + chromeW),
                          height: fit.height + chromeH + 4)
        // Only resize on a real change — applyLayout() runs from the 1s refresh
        // timer, and setting the same size every tick makes the window shimmer.
        if abs(window.contentLayoutRect.height - want.height) > 0.5
            || abs(window.contentLayoutRect.width - want.width) > 0.5 {
            window.setContentSize(want)
        }
    }

    /// Tail of the wake log — the one that records setup, wake and auto-wake.
    func updateConsole() {
        guard let s = try? String(contentsOfFile: "/tmp/sai-wake.log", encoding: .utf8) else {
            console.string = "(no log yet — it appears once SAI is launched or a wake fires)"; return
        }
        let tail = s.split(separator: "\n").suffix(150).joined(separator: "\n")
        guard tail != console.string else { return }
        console.string = tail
        console.scrollToEndOfDocument(nil)
    }

    func refresh() {
        // Keep the Recording tab current while it is being looked at. Without
        // this it showed whatever it said when you switched to it, so drawing
        // for ten minutes still read "Nothing recorded yet". Only when that tab
        // is actually selected: it stats the frames folder, and there is no
        // reason to do that once a second behind a tab nobody is looking at.
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

    /// Reflect the current setting and what the tablet says it can do.
    func refreshPressureUI() {
        guard pressurePopup != nil else { return }
        syncFeelControls()
        let detected = detectTabletFullScale()
        if let ov = storedMaxPressureOverride(),
           let idx = PressureCore.pressureChoices.firstIndex(of: ov) {
            pressurePopup.selectItem(at: idx + 1)
        } else {
            pressurePopup.selectItem(at: 0)                       // Auto
        }
        // Say WHY this number, and name the device it came from — otherwise
        // "4096" is just an unexplained figure, and with two tablets plugged in
        // there's no way to tell which one it came from.
        _ = detected
        let all = detectTablets()
        let inUse = PressureCore.maxPressure + 1
        let auto = storedMaxPressureOverride() == nil
        switch all.count {
        case 0:
            // With nothing plugged in, `inUse` is usually the value REMEMBERED
            // from the last tablet, not a default. Calling it "the safe default"
            // hid the fact that the app was running on stale information — and
            // hid the more useful message, which is that no tablet is connected.
            if !auto {
                pressureInfo.stringValue = "set by you: \(inUse) · no tablet connected to check against"
            } else if let cached = cachedDetectedFullScale(), cached + 1 == inUse {
                pressureInfo.stringValue =
                    "⚠️ no tablet connected — using \(inUse), remembered from the last one"
            } else {
                pressureInfo.stringValue =
                    "⚠️ no tablet connected — using the safe default \(inUse)"
            }
        case 1:
            let t = all[0]
            pressureInfo.stringValue = auto
                ? "\(t.name) reports \(t.fullScale + 1) levels — using that"
                : "set by you: \(inUse) · \(t.name) reports \(t.fullScale + 1)"
        default:
            let t = all[0]
            let others = all.dropFirst().map { "\($0.name) \($0.fullScale + 1)" }.joined(separator: ", ")
            pressureInfo.stringValue = auto
                ? "\(all.count) tablets connected — following the highest, \(t.name) (\(t.fullScale + 1)). Also: \(others)"
                : "set by you: \(inUse) · connected: \(t.name) \(t.fullScale + 1), \(others)"
        }
    }

    @objc func pressureChoiceChanged() {
        let detected = detectTabletFullScale()
        let idx = pressurePopup.indexOfSelectedItem
        if idx == 0 {
            try? FileManager.default.removeItem(atPath: appSupport() + "/pmax.txt")   // back to Auto
        } else {
            let v = PressureCore.pressureChoices[idx - 1]
            // More levels than the hardware has is not more detail — it is the
            // same steps spread wider, so noise stops being quantised away.
            // That is exactly what produced wobbly stroke widths in testing.
            if let d = detected, v > d {
                let c = osa("button returned of (display dialog \"Your tablet reports \(d + 1) pressure levels.\n\nSetting \(v + 1) doesn't give finer control — the same hardware steps get spread over a wider range, so sensor noise shows up as wobbly stroke width instead of being rounded away.\n\nUse it anyway?\" buttons {\"Cancel\", \"Use anyway\"} default button \"Cancel\" with icon caution)")
                guard c == "Use anyway" else { refreshPressureUI(); return }
            }
            saveMaxPressure(v)
        }
        PressureCore.maxPressure = savedMaxPressure()
        writeMaxPressureForDLL()
        refreshPressureUI()
        alertUser("Pressure set to \(PressureCore.maxPressure + 1) levels.\n\nSAI reads this once when it starts, so quit SAI completely and relaunch it to apply.")
    }

    @objc func gammaSliderMoved() {
        let g = (gammaSlider.doubleValue * 100).rounded() / 100      // 2dp, no jitter
        saveGamma(g)
        syncFeelControls()
    }

    /// One source of truth for both the preset popup and the fine control.
    func syncFeelControls() {
        let g = PressureCore.pressureGamma
        if feelPopup != nil {
            let idx = feelChoices.enumerated().min { abs($0.1.1 - g) < abs($1.1.1 - g) }?.offset ?? 2
            feelPopup.selectItem(at: idx)
        }
        if gammaSlider != nil { gammaSlider.doubleValue = g }
        if gammaLabel != nil {
            let name = abs(g - 1.0) < 0.03 ? "linear" : (g < 1 ? "softer" : "firmer")
            gammaLabel.stringValue = String(format: "%.2f (%@)", g, name)
        }
        if curveView != nil { curveView.gamma = g }
    }

    @objc func feelChanged() {
        let g = feelChoices[feelPopup.indexOfSelectedItem].1
        saveGamma(g)
        syncFeelControls()
        // No SAI restart needed: the curve is applied before the value is sent.
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





    // Start/stop the live pressure test. Doubles as a real Input-Monitoring check:
    // if the tap can't be created, the permission isn't granted to this build yet.
    @objc func testTapped() {
        if testing { stopTest(); return }
        guard startPressureEngineOnce() else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            alertUser("Couldn't read the tablet yet.\n\nIn System Settings → Privacy & Security → Input Monitoring, turn ON \"SAI Pen Pressure\", then reopen this app and try Test again.")
            return
        }
        testing = true
        testPeakSeen = 0
        g_rawSeen.removeAll()          // fresh census per test run
        testBtn.title = "Stop Test"
        testHint.isHidden = false; barRow.isHidden = false
        settingsScratch?.clear()
        applyLayout()
        // fast (~60fps), .common-mode timer so the bar tracks the pen instantly and
        // keeps updating even while the window is being interacted with. The bar is
        // custom-drawn (no easing), so it jumps to the real value like the % does.
        let t = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let p = max(0, lastKeyP)                 // lastKeyP is -1 until a pen is first seen
            let maxP = PressureCore.maxPressure
            self.pressureBar.value = CGFloat(p) / CGFloat(maxP)
            // raw / full-scale, then percent — so the actual level count is visible
            self.pressureLabel.stringValue = "\(p) / \(maxP)   (\(Int((Double(p) / Double(maxP) * 100).rounded()))%)"
            if p > self.testPeakSeen { self.testPeakSeen = p }
            if self.curveView != nil { self.curveView.live = g_lastRawPressure }
            // RAW is what the tablet reported; distinct-raw is the empirical read
            // of its true resolution. If distinct stops climbing well below the
            // configured levels, the extra range is upsampling, not detail.
            self.testHint.stringValue = String(
                format: "sending %d levels · peak %d · raw from tablet %.6f · %d distinct raw values seen",
                maxP + 1, self.testPeakSeen, g_lastRawPressure, g_rawSeen.count)
        }
        RunLoop.main.add(t, forMode: .common)
        testTimer = t
    }

    func stopTest() {
        testing = false
        testTimer?.invalidate(); testTimer = nil
        if testBtn != nil { testBtn.title = "Test pen" }
        if testHint != nil { testHint.isHidden = true }
        if barRow != nil { barRow.isHidden = true }
        applyLayout()
    }

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
            let ok = ensureSetup(sai, wine)
            DispatchQueue.main.async {
                guard ok else { self.subtitle.stringValue = "Setup failed. Re-check the SAI folder."; self.refresh(); return }
                if startPressureEngineOnce() {
                    self.running = true
                    launchSAIApp()
                    self.subtitle.stringValue = "Running — pressure is active. Close SAI to quit."
                    self.window.miniaturize(nil)
                } else {
                    self.relaunchForPermission()
                }
            }
        }
    }

}

let g_setup = SetupController()     // strong ref (NSApplication.delegate is weak)
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.regular)
nsApp.delegate = g_setup
nsApp.run()

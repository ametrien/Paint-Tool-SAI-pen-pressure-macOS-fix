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
let _pmaxInit: Void = { PressureCore.maxPressure = savedMaxPressure() }()
let isAppMode = CommandLine.arguments.contains("--app") || Bundle.main.bundlePath.hasSuffix(".app")
// Wine prefix the app manages. Override with SAI_PREFIX (e.g. to test from
// scratch in a throwaway location without touching a real setup).
let appPrefix: String = {
    if let p = ProcessInfo.processInfo.environment["SAI_PREFIX"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return NSString(string: "~/SAI2-pressure").expandingTildeInPath
}()

func appSupport() -> String {
    // where the saved SAI-folder config lives; override with SAIPP_CONFIG_DIR
    // (used to test the first-run wizard without clobbering a real config).
    let d = ProcessInfo.processInfo.environment["SAIPP_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath }
        ?? NSString(string: "~/Library/Application Support/SAIPenPressure").expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
func savedSAIPath() -> String? {
    guard let s = try? String(contentsOfFile: appSupport() + "/config.txt", encoding: .utf8) else { return nil }
    let p = s.trimmingCharacters(in: .whitespacesAndNewlines); return p.isEmpty ? nil : p
}
// ---- pressure resolution (issue #21) ---------------------------------------
// The helper and the DLL must agree on full-scale pressure, and SAI reads the
// axis once at WTOpen. So the choice is stored on the mac side and mirrored
// into the prefix as C:\wt_pmax.txt BEFORE SAI launches; the DLL reads that at
// load. One value, two readers, no way for them to disagree.
func savedMaxPressure() -> Int {
    guard let s = try? String(contentsOfFile: appSupport() + "/pmax.txt", encoding: .utf8),
          let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          PressureCore.pressureChoices.contains(v) else { return 1023 }
    return v
}
func saveMaxPressure(_ v: Int) {
    try? "\(v)".write(toFile: appSupport() + "/pmax.txt", atomically: true, encoding: .utf8)
    PressureCore.maxPressure = v
}
/// Mirror the setting into the prefix so the DLL picks it up on next SAI launch.
func writeMaxPressureForDLL() {
    let dir = "\(appPrefix)/drive_c"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? "\(PressureCore.maxPressure)".write(toFile: "\(dir)/wt_pmax.txt", atomically: true, encoding: .ascii)
}

func saveSAIPath(_ p: String) { try? p.write(toFile: appSupport() + "/config.txt", atomically: true, encoding: .utf8) }

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
func licenseStashDir() -> String {
    let d = appSupport() + "/license"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
func slcFiles(in dir: String) -> [String] {
    (((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.lowercased().hasSuffix(".slc") }).sorted()
}

// WHERE SAI LOOKS FOR THE CERTIFICATE CHANGED BETWEEN BUILDS:
//   - older Ver.2 builds read it from the folder holding sai2.exe;
//   - the 2026-07-12 "Technical Preview Major Renovated" build reads it from a
//     `settings` folder instead (the renovation moved config/licence paths).
// Guessing wrong looks exactly like an invalid licence — SAI just refuses to
// save, with no hint that the file is in the wrong folder. A certificate is
// 128 bytes, so write BOTH and let whichever build you run find its own.
var licenseDirs: [String] { [prefixSAIDir, "\(prefixSAIDir)/settings"] }

func installedLicenseName() -> String? {
    for d in licenseDirs { if let f = slcFiles(in: d).first { return f } }
    return nil
}

// ---- which SAI build is installed? -----------------------------------------
// SAI ships its own changelog, `history.txt`, newest entry first, with the build
// date as a bare `YYYY-MM-DD` line. Reading that beats guessing from the folder
// name (users rename them) or the exe size (changes every release).
//
// We report the DATE and nothing more. It is tempting to infer the branch —
// "Major Renovated" vs "Technical Preview Stable" — from a cutoff date, but that
// is wrong: SYSTEMAX updates BOTH branches, so a Stable build released after the
// renovated one carries a later date and would be misclassified. There is no
// date at which one branch starts and the other stops.
//
// It doesn't matter anyway: the licence is written to every location SAI might
// read, so nothing depends on knowing the branch. A build date is a fact we can
// show without it going stale; a branch label would be a guess that rots.
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

/// Which of the two locations actually hold a certificate right now. Shown in
/// the UI because "it says installed but SAI won't save" is impossible to debug
/// blind — seeing the real paths makes a half-install obvious at a glance.
func licenseLocations() -> [String] {
    licenseDirs.filter { !slcFiles(in: $0).isEmpty }
}
func licenseLocationSummary() -> String {
    let have = licenseLocations()
    if have.count == licenseDirs.count { return "in both locations (works on old and new SAI builds)" }
    if have.isEmpty { return "not installed" }
    return have.contains(prefixSAIDir) ? "only next to sai2.exe (older builds)"
                                       : "only in settings/ (Major Renovated build)"
}

@discardableResult
func installLicenseFile(_ src: String) -> Bool {
    let name = (src as NSString).lastPathComponent
    var wroteAny = false
    for dir in licenseDirs {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dst = "\(dir)/\(name)"
        if dst == src { wroteAny = true; continue }        // already in place
        try? FileManager.default.removeItem(atPath: dst)
        if (try? FileManager.default.copyItem(atPath: src, toPath: dst)) != nil { wroteAny = true }
    }
    guard wroteAny else { return false }
    let stash = "\(licenseStashDir())/\(name)"                  // survive a rebuild
    try? FileManager.default.removeItem(atPath: stash)
    try? FileManager.default.copyItem(atPath: src, toPath: stash)
    return true
}
/// Put every stashed certificate back after a rebuild. Best-effort and silent:
/// a rebuilt prefix has a new System ID, so the old cert may no longer validate —
/// the UI says so rather than pretending the restore guarantees activation.
func restoreStashedLicenses() {
    let stash = licenseStashDir()
    guard !slcFiles(in: stash).isEmpty else { return }
    for f in slcFiles(in: stash) {
        installLicenseFile("\(stash)/\(f)")      // writes every location SAI might read
    }
}

// ---- setup / repair / rebuild ----------------------------------------------
enum SetupMode {
    case ensure     // install only if nothing usable is there (or the source changed)
    case repair     // re-copy SAI + the bridge over the existing prefix; keep licence
    case rebuild    // delete the whole prefix and build it from scratch; restore licence
}

/// Install the pressure bridge (our DLL + the registry overrides) into the prefix.
/// Split out so repair can redo it without touching SAI itself.
func installBridge(_ wine: String) {
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    if let res = Bundle.main.resourcePath {
        let sys = "\(appPrefix)/drive_c/windows/system32"
        try? FileManager.default.createDirectory(atPath: sys, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: "\(sys)/wintab32.dll")
        try? FileManager.default.copyItem(atPath: "\(res)/wintab32.dll", toPath: "\(sys)/wintab32.dll")
    }
    runProc(wine, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "wintab32",
                   "/t", "REG_SZ", "/d", "native,builtin", "/f"], env: env)
}

/// Keep the DLL inside the prefix identical to the one shipped in this app.
///
/// The helper and the DLL are a matched pair: they share `maxPressure` /
/// `WTC_MAX_PRESS` over a wire format with no version field. A new helper
/// scaling to 8191 against an old DLL that clamps at 1023 would pin every
/// stroke at full pressure — worse than the quantisation it fixes (issue #21).
///
/// Users update the app without re-running setup all the time, which would
/// leave a stale DLL in the prefix forever. So check on every launch and heal
/// it: a byte compare of a 138 KB file is far cheaper than that failure mode.
@discardableResult
func ensureBridgeUpToDate(_ wine: String?) -> Bool {
    guard let res = Bundle.main.resourcePath else { return false }
    let shipped = "\(res)/wintab32.dll"
    let sys = "\(appPrefix)/drive_c/windows/system32"
    let installed = "\(sys)/wintab32.dll"
    guard let want = FileManager.default.contents(atPath: shipped) else { return false }
    if FileManager.default.contents(atPath: installed) == want { return false }   // already current
    wlog("bridge: installed wintab32.dll differs from the shipped one — updating")
    try? FileManager.default.createDirectory(atPath: sys, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: installed)
    guard (try? FileManager.default.copyItem(atPath: shipped, toPath: installed)) != nil else { return false }
    if let w = wine {                        // re-assert the override, harmless if already set
        runProc(w, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "wintab32",
                    "/t", "REG_SZ", "/d", "native,builtin", "/f"],
                env: ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"])
    }
    return true
}

@discardableResult
func performSetup(_ saiSrc: String, _ wine: String, mode: SetupMode = .ensure, quiet: Bool = false) -> Bool {
    if mode == .ensure, saiInstalledInPrefix(), !prefixIsStale() { return true }

    // Fail fast (before the ~1-minute wineboot) with a SPECIFIC message if the
    // chosen SAI folder is gone or doesn't actually contain sai2.exe — e.g. the
    // user moved/deleted it after picking it, or picked the wrong level.
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: saiSrc, isDirectory: &isDir), isDir.boolValue else {
        alertUser("The SAI folder you chose can't be found anymore:\n\n\(saiSrc)\n\nIt may have been moved, renamed, or deleted. Reopen the app and choose your SAI Ver.2 folder again.")
        try? FileManager.default.removeItem(atPath: appSupport() + "/config.txt")   // clear the stale path so the app re-asks
        return false
    }
    guard FileManager.default.fileExists(atPath: "\(saiSrc)/sai2.exe") else {
        alertUser("That folder doesn't contain sai2.exe:\n\n\(saiSrc)\n\nPick the folder that DIRECTLY contains sai2.exe (usually named like \"SAI Ver.2 64bit ...\").")
        try? FileManager.default.removeItem(atPath: appSupport() + "/config.txt")
        return false
    }

    if !quiet {
        let what = mode == .rebuild ? "Rebuilding the Wine prefix from scratch"
                 : (saiInstalledInPrefix() ? "Reinstalling SAI into the Wine prefix"
                                           : "Setting up SAI for the first time")
        alertUser("\(what) — this takes about a minute after you click OK. Please wait for SAI to appear.")
    }

    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    if mode == .rebuild {
        // The whole point of a rebuild: nothing from the old prefix survives.
        // The licence is restored afterwards from our own stash, not from here.
        try? FileManager.default.removeItem(atPath: appPrefix)
    }
    runProc(wine, ["wineboot", "-u"], env: env)

    // Re-copy SAI. For repair/rebuild the destination is cleared first, so files
    // deleted from the source don't linger and a broken install can't survive.
    if mode != .ensure, FileManager.default.fileExists(atPath: prefixSAIDir) {
        // keep any certificate that's already in there
        for f in slcFiles(in: prefixSAIDir) { installLicenseFile("\(prefixSAIDir)/\(f)") }
        try? FileManager.default.removeItem(atPath: prefixSAIDir)
    }
    try? FileManager.default.createDirectory(atPath: prefixSAIDir, withIntermediateDirectories: true)
    runProc("/bin/cp", ["-R", "\(saiSrc)/.", prefixSAIDir])
    guard saiInstalledInPrefix() else {
        alertUser("Something went wrong copying SAI into the Wine prefix. Check that you have free disk space and that the SAI folder is readable, then reopen the app and try again."); return false
    }

    installBridge(wine)
    restoreStashedLicenses()
    setInstalledSrcPath(saiSrc)          // the prefix now matches this source
    return saiInstalledInPrefix()
}

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
func isForeignSAIWindow(_ w: [String: Any]) -> Bool {
    let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
    guard owner.contains("wine") || owner.contains("sai") else { return false }
    let pid = pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0)
    return pid != g_myPID
}

// Is any SAI/Wine window still on screen? Used to decide when SAI has really
// closed (see launchSAIApp's terminationHandler).
func saiWindowIsOpen() -> Bool {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list {
        guard isForeignSAIWindow(w) else { continue }
        if (w[kCGWindowLayer as String] as? Int ?? 0) == 0 { return true }
    }
    return false
}

func pollUntilSAICloses() {
    let t = Timer(timeInterval: 2.0, repeats: true) { timer in
        if !saiWindowIsOpen() { timer.invalidate(); exit(0) }
    }
    RunLoop.main.add(t, forMode: .common)
}

// LAUNCH (runs only after the pressure tap is active): start SAI; quit the app
// when SAI closes.
func launchSAIApp() {
    writeMaxPressureForDLL()      // must land before the DLL loads
    applyWineShortcutRemap(g_wine)          // Cmd->Ctrl via Wine (every launch; idempotent)
    let pf = "\(appPrefix)/drive_c/wt_pressure.txt"
    try? "0".write(toFile: pf, atomically: true, encoding: .ascii)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: g_wine); p.arguments = ["sai2.exe"]
    p.currentDirectoryURL = URL(fileURLWithPath: "\(appPrefix)/drive_c/SAI2")
    var e = ProcessInfo.processInfo.environment
    e["WINEPREFIX"] = appPrefix; e["WINEDEBUG"] = "-all"
    p.environment = e
    p.terminationHandler = { _ in
        try? "0".write(toFile: pf, atomically: true, encoding: .ascii)
        // The process we spawned exiting does NOT always mean SAI closed — Wine
        // can hand off to another process and let this one exit immediately,
        // which used to make us quit while SAI was still on screen. Only exit
        // once no SAI window is left.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !saiWindowIsOpen() { exit(0) }
            else { pollUntilSAICloses() }
        }
    }
    try? p.run()                                            // async; quits the app when SAI closes
}

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
var inProximity = false
var lastSendMs = CFAbsoluteTimeGetCurrent()

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
        inProximity = false                    // stops the hover keepalive too
        return
    }

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
func keepAlive() {
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
    if PressureCore.keepAliveShouldResend(inProximity: inProximity, lastPressure: lastKeyP,
                                          secondsSinceLastSend: CFAbsoluteTimeGetCurrent() - lastSendMs) {
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
        inProximity = event.getIntegerValueField(.tabletProximityEventEnterProximity) != 0
        if !inProximity {
            emit(pressure: 0, loc: event.location)
            flushPendingUp()   // pen left range: no bounce can follow, end the touch now
        }
    case .tabletPointer:
        g_evTabletPtr += 1
        g_lastTabletEvAt = CFAbsoluteTimeGetCurrent(); g_penEverSeen = true
        inProximity = true
        let pr = event.getDoubleValueField(.tabletEventPointPressure)
        emit(pressure: Int(pr * Double(PressureCore.maxPressure)), loc: event.location)
    case .leftMouseUp:
        if isTabletMouse(event) { emit(pressure: 0, loc: event.location) }   // pen tip lift (still hovering)
    case .mouseMoved, .leftMouseDown, .leftMouseDragged:
        if isTabletMouse(event) {
            g_evTabletMouse += 1
            g_lastTabletEvAt = CFAbsoluteTimeGetCurrent(); g_penEverSeen = true
            inProximity = true
            let pr = event.getDoubleValueField(.tabletEventPointPressure)
            emit(pressure: Int(pr * Double(PressureCore.maxPressure)), loc: event.location)
        } else {
            g_evPlainMouse += 1
            inProximity = false   // real mouse/trackpad -> pen not in use, let SAI have the mouse
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
        break
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
    let mask: CGEventMask =
        (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)    |
        (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue) |
        (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)      |
        (CGEventMask(1) << CGEventType.mouseMoved.rawValue)       |
        (CGEventMask(1) << CGEventType.tabletPointer.rawValue)    |
        (CGEventMask(1) << CGEventType.tabletProximity.rawValue)  |
        (CGEventMask(1) << CGEventType.keyDown.rawValue)              // wake hotkey detection
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

// ---- App mode: a small setup wizard (AppKit) -------------------------------
final class SetupController: NSObject, NSApplicationDelegate {
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
    var settingsOnlyViews: [NSView] = []
    var advanced = false
    var advancedBtn: NSButton!
    var allSetLabel: NSTextField!
    var autoBtn: NSButton!
    var autoRunning = false
    var secondaryRow: NSStackView!
    var devSection: NSStackView!
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
    func setUpStatusItem() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // ICON: an SF Symbol TEMPLATE image, not the old "🖊" emoji title.
        // U+1F58A renders as a dark-grey pen — near-invisible on a dark menu bar
        // (and it's a colour glyph, so it can't adapt). A template image is
        // recoloured by AppKit to match the menu bar in both light and dark.
        if let base = NSImage(systemSymbolName: "applepencil", accessibilityDescription: "SAI Pen Pressure"),
           let img = base.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
            img.isTemplate = true
            si.button?.image = img
        } else {
            si.button?.title = "✏️"     // high-contrast fallback (older macOS)
        }
        si.button?.toolTip = "SAI Pen Pressure"
        // Give the item a STABLE identity. Without one, AppKit derives the
        // menu-bar slot from the app's code-signing identity — and make-app.sh
        // signs ad-hoc, so every rebuild looks like a brand-new app and gets no
        // allocated slot (it landed at x=1321, underneath the clock, invisible).
        si.autosaveName = "SAIPenPressureStatusItem"
        si.isVisible = true
        // Diagnostic: where did macOS actually put us? A menu bar with no room
        // left (long app menus + the notch) silently drops the item, which looks
        // exactly like "the icon vanished". Logged so field reports can tell the
        // two apart. See wlog() — always on, cheap, fires once at startup.
        for t in [1.5, 5.0, 12.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak si] in
                guard let si = si else { wlog("statusItem@\(t)s: DEALLOCATED"); return }
                let f = si.button?.window?.frame
                wlog("statusItem@\(t)s: visible=\(si.isVisible) len=\(si.length) frame=\(f.map { "\($0)" } ?? "nil")")
            }
        }
        si.menu = makeMenu()
        statusItem = si
    }

    /// Rebuild both menus after something that changes their contents (dev mode).
    func rebuildMenus() { statusItem?.menu = makeMenu() }

    /// One menu definition shared by the 🖊 menu-bar item and the right-click
    /// Dock menu, so the two can't drift apart.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, state: NSControl.StateValue? = nil, indent: Int = 0) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.indentationLevel = indent
            if let s = state { it.state = s }
            menu.addItem(it)
        }
        add("Wake SAI window (if stuck)   ⌃⌥⌘Space", #selector(wakeSAI))
        add("Auto-wake when returning to SAI", #selector(toggleAutoWake(_:)), state: autoWake ? .on : .off)
        menu.addItem(.separator())
        add("Open Setup window", #selector(showSetupWindow))
        add("Reinstall / Repair…", #selector(reinstallTapped))
        add("Install License (.slc)…", #selector(licenseTapped))
        menu.addItem(.separator())
        // Dev mode: a checkbox that reveals the diagnostic items beneath it.
        add("Developer mode", #selector(toggleDevMode(_:)), state: devMode ? .on : .off)
        if devMode {
            add("Copy diagnostics", #selector(copyDiagnostics), indent: 1)
            add("Reveal Wine prefix in Finder", #selector(revealPrefix), indent: 1)
            add("Open helper log", #selector(openHelperLog), indent: 1)
            add("Open wake log", #selector(openWakeLog), indent: 1)
            add("Open DLL log", #selector(openDLLLog), indent: 1)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc func reinstallTapped() { showSetupWindow(); reinstallMenu() }
    @objc func licenseTapped()   { showSetupWindow(); chooseLicense() }

    @objc func showSetupWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Right-click on our Dock icon. Left-click focuses SAI; the useful actions —
    // including the Developer-mode toggle — live here, which is the second place
    // (besides the menu-bar item) you can reach them.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { makeMenu() }


    func applicationDidBecomeActive(_ note: Notification) { refresh() }   // re-check when refocused

    // ---- version / update check -----------------------------------------------
    var versionLabel: NSTextField!
    var updateLabel: NSTextField!
    var updateBtn: NSButton!
    var latestTag: String?
    var latestNotes: String = ""
    let repoSlug = "ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix"

    func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// true if a > b, comparing dotted numeric versions ("0.1.4" > "0.1.3")
    func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // Ask GitHub for the newest release. Read-only, anonymous, ~1 request per
    // launch; silently does nothing if offline.
    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let d = data,
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let tag = j["tag_name"] as? String else { return }
            let notes = (j["body"] as? String) ?? ""
            DispatchQueue.main.async { self.showUpdateStatus(tag: tag, notes: notes) }
        }.resume()
    }

    func showUpdateStatus(tag: String, notes: String) {
        latestTag = tag; latestNotes = notes
        guard updateLabel != nil else { return }
        if isNewer(tag, than: currentVersion()) {
            // Keep the label SHORT — a release-notes teaser here overflowed the
            // row. The first meaningful line goes in the tooltip instead (with
            // markdown markers stripped); full notes are behind the button.
            let first = notes.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(">") } ?? ""
            let teaser = first.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            updateLabel.stringValue = "· Update available: \(tag)"
            updateLabel.toolTip = teaser.isEmpty ? nil : teaser
            updateLabel.textColor = .controlAccentColor
            updateBtn.isHidden = false
        } else {
            updateLabel.stringValue = "· up to date"
            updateLabel.toolTip = nil
            updateLabel.textColor = .tertiaryLabelColor
            updateBtn.isHidden = true
        }
    }

    @objc func openReleasePage() {
        let s = latestTag.map { "https://github.com/\(repoSlug)/releases/tag/\($0)" }
            ?? "https://github.com/\(repoSlug)/releases/latest"
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

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
        testBtn = NSButton(title: "Test pen", target: self, action: #selector(testTapped))
        testBtn.bezelStyle = .rounded; testBtn.controlSize = .small
        let wakeBtn = NSButton(title: "Wake SAI (if stuck)", target: self, action: #selector(wakeSAI))
        wakeBtn.bezelStyle = .rounded; wakeBtn.controlSize = .small
        advancedBtn = NSButton(title: "Settings ⌄", target: self, action: #selector(toggleAdvanced))
        advancedBtn.bezelStyle = .rounded; advancedBtn.controlSize = .small
        secondaryRow = NSStackView(); secondaryRow.orientation = .horizontal
        secondaryRow.alignment = .centerY; secondaryRow.spacing = 8
        secondaryRow.addArrangedSubview(testBtn)
        secondaryRow.addArrangedSubview(wakeBtn)
        secondaryRow.addArrangedSubview(advancedBtn)
        content.addArrangedSubview(secondaryRow)

        testHint = lbl("Press your pen on the tablet — the bar should move.", 10, color: .secondaryLabelColor)
        testHint.isHidden = true
        content.addArrangedSubview(testHint)
        barRow = NSStackView(); barRow.orientation = .horizontal; barRow.alignment = .centerY; barRow.spacing = 10
        pressureBar = PressureBar()
        pressureBar.widthAnchor.constraint(equalToConstant: 240).isActive = true
        pressureBar.heightAnchor.constraint(equalToConstant: 12).isActive = true
        pressureLabel = lbl("0%", 11, bold: true)
        pressureLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        barRow.addArrangedSubview(pressureBar); barRow.addArrangedSubview(pressureLabel)
        barRow.isHidden = true
        content.addArrangedSubview(barRow)

        // --- one-button recovery, in Settings ---------------------------------
        // The whole point: a single obvious action that rebuilds everything, for
        // when the prefix is broken and you don't want to reason about which
        // half is at fault.
        let scratchRow = NSStackView(); scratchRow.orientation = .horizontal; scratchRow.spacing = 8
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
        settingsOnlyViews.append(scratchRow)
        content.addArrangedSubview(scratchRow)

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
        content.addArrangedSubview(devSection)

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

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: rowWidth + 48, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SAI Pen Pressure"
        window.contentView = content
        window.isReleasedWhenClosed = false
        applyLayout()               // sizes the window to whichever tier is showing
        window.center()
        window.makeKeyAndOrderFront(nil)
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
        settingsOnlyViews.forEach { $0.isHidden = !advanced }
        devSection.isHidden = !advanced
        devCheck.state = devMode ? .on : .off
        consoleScroll.isHidden = !devMode
        devSection.arrangedSubviews.forEach { if $0 !== devCheck { $0.isHidden = !devMode } }
        advancedBtn.title = advanced ? "Settings ⌃" : "Settings ⌄"
        if devMode && advanced { updateConsole() }
        window.layoutIfNeeded()
        let fit = content.fittingSize
        let want = NSSize(width: max(rowWidth + 48, fit.width), height: fit.height)
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

    @objc func extraTapped(_ sender: NSButton) {
        reqs[sender.tag].extraAction?()
    }

    @objc func fixTapped(_ sender: NSButton) {
        reqs[sender.tag].fix()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    /// Find folders that actually contain sai2.exe, so we can OFFER the right
    /// one instead of dropping the user into a blank file picker and hoping they
    /// remember where they unzipped it. Spotlight first (instant, whole disk),
    /// with a shallow scan of the usual places as a fallback when Spotlight is
    /// disabled or the folder isn't indexed.
    func findSAIFolders() -> [String] {
        var out: [String] = []
        func consider(_ dir: String) {
            guard FileManager.default.fileExists(atPath: "\(dir)/sai2.exe") else { return }
            guard !dir.hasPrefix(appPrefix) else { return }     // our own copy: a destination, not a source
            guard !out.contains(dir) else { return }
            out.append(dir)
        }
        for line in runCapture("/usr/bin/mdfind", ["kMDItemFSName == 'sai2.exe'"]).split(separator: "\n") {
            consider((String(line) as NSString).deletingLastPathComponent)
        }
        if out.isEmpty {
            let home = NSHomeDirectory()
            let roots = ["\(home)/Documents", "\(home)/Downloads", "\(home)/Desktop",
                         "\(home)/Applications", "/Applications"]
            for root in roots {
                consider(root)
                for sub in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []) {
                    consider("\(root)/\(sub)")
                }
            }
        }
        return out
    }

    func chooseSAI() {
        // Suggest what we found before opening a picker.
        let found = findSAIFolders()
        if let best = found.first {
            let shown = (best as NSString).abbreviatingWithTildeInPath
            if found.count == 1 {
                let c = osa("button returned of (display dialog \"Found SAI here:\n\n\(shown)\n\nUse this folder?\" buttons {\"Choose another…\", \"Use this folder\"} default button \"Use this folder\" with icon note)")
                if c == "Use this folder" { adoptSAIFolder(best); return }
            } else {
                // several installs — let the user pick which one
                let items = found.map { "\"\(($0 as NSString).abbreviatingWithTildeInPath)\"" }.joined(separator: ", ")
                if let picked = osa("choose from list {\(items)} with prompt \"Found more than one SAI folder — pick the one to use:\" OK button name \"Use this folder\" cancel button name \"Choose another…\""),
                   picked != "false" {
                    let full = found.first { ($0 as NSString).abbreviatingWithTildeInPath == picked }
                    if let f = full { adoptSAIFolder(f); return }
                }
            }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        // Open the picker somewhere useful rather than at the last-used folder.
        panel.directoryURL = URL(fileURLWithPath: (found.first as NSString?)?.deletingLastPathComponent
                                 ?? savedSAIPath().map { ($0 as NSString).deletingLastPathComponent }
                                 ?? NSHomeDirectory() + "/Documents")
        panel.prompt = "Choose"
        panel.message = found.isEmpty
            ? "Select your SAI Ver.2 folder — the one that directly contains sai2.exe"
            : "Select your SAI Ver.2 folder (we found one at \((found[0] as NSString).abbreviatingWithTildeInPath))"
        if panel.runModal() == .OK, let url = panel.url {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("sai2.exe").path) {
                adoptSAIFolder(url.path)
            } else {
                alertUser("That folder doesn't contain sai2.exe. Pick the folder that directly contains sai2.exe.")
            }
        }
        refresh()
    }

    /// Record a chosen source folder and, if the prefix already holds a
    /// different build, offer to apply it now. Picking a folder used to change
    /// nothing but a label (issue #11).
    func adoptSAIFolder(_ path: String) {
        saveSAIPath(path)
        if saiInstalledInPrefix() && prefixIsStale() {
            let c = osa("button returned of (display dialog \"Copy this SAI into the Wine prefix now?\n\nSAI runs from a copy inside \(( prefixSAIDir as NSString).abbreviatingWithTildeInPath). Until it's copied, SAI will keep running the previous version.\" buttons {\"Later\", \"Reinstall now\"} default button \"Reinstall now\" with icon note)")
            if c == "Reinstall now" { doReinstall(mode: .repair) }
        }
        refresh()
    }

    /// Make macOS ask again. Once Input Monitoring has been answered for an app
    /// identity, `IOHIDRequestAccess` silently returns the cached answer forever
    /// and the only route left is hunting the app down in a file picker.
    /// `tccutil reset` clears the entry so the native prompt fires again.
    ///
    /// Deliberately narrow and deliberately not silent: it targets THIS app's
    /// bundle id only (never a blanket reset), it can only REMOVE a grant —
    /// never add one, you still approve in System Settings — and it asks first.
    @objc func resetOwnPermission() {
        let bid = Bundle.main.bundleIdentifier ?? "com.runasharp.saipenpressure"
        let c = osa("button returned of (display dialog \"Make macOS ask for Input Monitoring again?\n\nThis clears only this app's own permission entry (\(bid)) so the system prompt reappears — much quicker than adding the app by hand.\n\nIt cannot grant anything: you still approve it in System Settings. The app will relaunch.\" buttons {\"Cancel\", \"Reset & ask again\"} default button \"Reset & ask again\" with icon caution)")
        guard c == "Reset & ask again" else { return }
        _ = runCapture("/usr/bin/tccutil", ["reset", "ListenEvent", bid])
        // The prompt only fires on a fresh launch, so bounce ourselves.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 1; open '\(Bundle.main.bundlePath)'"]
        try? p.run()
        exit(0)
    }

    /// Granting Input Monitoring means finding this app in a file picker, which
    /// is the fiddliest step in the whole setup. Do the finding FOR the user:
    /// open the right Settings pane, reveal the app in Finder so it can be
    /// dragged straight in, and put its path on the clipboard to paste.
    @objc func grantInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)      // native prompt, if it still applies
        let appPath = Bundle.main.bundlePath
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appPath, forType: .string)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
        alertUser("""
        Turn ON "SAI Pen Pressure" in the list that just opened.

        If it isn't listed, click + and either:
          • drag "SAI Pen Pressure" from the Finder window that just opened, or
          • press ⇧⌘G and paste (⌘V) — the path is already on your clipboard.

        This app's path:
        \(appPath)

        Tip: if you see several "SAI Pen Pressure" entries from older builds, turn off or remove the old ones — only the one at the path above is this build.
        """)
    }

    // ---- licence ------------------------------------------------------------
    // This project does NOT supply, generate or resell licences and has no
    // connection to SYSTEMAX. All it does is copy a certificate the user
    // already bought into the folder SAI actually reads. Say so plainly, in
    // the UI, before the file picker — not just in the README.
    static let saiOfficialURL = "https://www.systemax.jp/en/sai/"

    @objc func openOfficialSAISite() {
        if let u = URL(string: SetupController.saiOfficialURL) { NSWorkspace.shared.open(u) }
    }

    func chooseLicense() {
        if installedLicenseName() == nil {
            let c = osa("button returned of (display dialog \"You need your own SAI license certificate (.slc).\n\nPaintTool SAI is commercial software by SYSTEMAX. Buy a license and download your .slc from the official site — this app is NOT affiliated with SYSTEMAX, and it cannot supply, generate or activate a license for you.\n\nIt only copies a .slc you already own into the folder SAI reads.\" buttons {\"Cancel\", \"Open official site\", \"I have my .slc\"} default button \"I have my .slc\" with icon note)")
            if c == "Open official site" { openOfficialSAISite(); return }
            if c != "I have my .slc" { return }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        panel.message = "Select your SAI license certificate (.slc)"
        // .slc isn't a registered system type, so filter loosely and validate the
        // extension ourselves — a hard UTType filter can grey out the real file.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "slc" else {
            alertUser("That isn't a .slc certificate:\n\n\(url.lastPathComponent)\n\nPick the sai-*.slc file you downloaded from SYSTEMAX.")
            return
        }
        if installLicenseFile(url.path) {
            // Show the REAL paths. SAI reads the certificate from a different
            // folder depending on the build, so "installed" alone doesn't tell
            // you whether the build you run will actually find it.
            let paths = licenseLocations()
                .map { "  \(($0 as NSString).abbreviatingWithTildeInPath)/\(url.lastPathComponent)" }
                .joined(separator: "\n")
            alertUser("""
            License installed — copied to both places SAI might read it:

            \(paths)

            Older SAI builds read it next to sai2.exe; the 2026-07-12 "Major Renovated" preview reads it from settings/. Copying both means whichever build you run finds it.

            Quit SAI completely and relaunch for it to take effect (closing the window isn't enough).
            """)
        } else {
            alertUser("Couldn't copy the license into the Wine prefix. Check that \(( prefixSAIDir as NSString).abbreviatingWithTildeInPath) is writable, then try again.")
        }
        refresh()
    }

    // ---- reinstall / repair (issue #10) -------------------------------------
    func reinstallMenu() {
        guard let wine = wineBin() else {
            alertUser("Wine isn't installed yet — install it first (top row)."); return
        }
        guard savedSAIPath() != nil else { chooseSAI(); return }
        _ = wine
        let c = osa("button returned of (display dialog \"How much do you want to reinstall?\n\n• Repair — copy SAI and the pressure bridge back into the existing Wine prefix. Keeps your license and Wine settings. Try this first.\n\n• Full rebuild — delete \(( appPrefix as NSString).abbreviatingWithTildeInPath) entirely and build it from scratch. Use this if the prefix is damaged. Your license is saved and put back automatically.\" buttons {\"Cancel\", \"Full rebuild…\", \"Repair\"} default button \"Repair\" with icon caution)")
        switch c {
        case "Repair":       doReinstall(mode: .repair)
        case "Full rebuild…":
            let ok = osa("button returned of (display dialog \"Delete and rebuild \(( appPrefix as NSString).abbreviatingWithTildeInPath)?\n\nEverything in that folder is removed, including anything you put there by hand. SAI is copied in again from your source folder, and your saved license is restored.\" buttons {\"Cancel\", \"Rebuild\"} default button \"Cancel\" with icon caution)")
            if ok == "Rebuild" { doReinstall(mode: .rebuild) }
        default: break
        }
    }

    // ONE button: a true factory reset. Wipes the prefix, FORGETS every
    // remembered path, optionally removes Wine, then starts setup from zero.
    // Deliberately keeps the licence stash — re-buying a certificate is not a
    // reasonable price for "reinstall", and it's the one thing we can't recreate.
    @objc func installFromScratch() {
        let hadWine = wineBin() != nil
        let ours = wineInstalledByUs()
        var bullets = "• delete \(( appPrefix as NSString).abbreviatingWithTildeInPath) (the whole Wine prefix)\n• forget your saved SAI folder\n• forget which build was installed"
        bullets += "\n• KEEP your saved license, and put it back afterwards"
        let c = osa("button returned of (display dialog \"Reset everything and start over?\n\nThis will:\n\n\(bullets)\n\nThen it asks you to pick your SAI folder again and rebuilds from scratch. Takes about a minute.\" buttons {\"Cancel\", \"Reset everything\"} default button \"Cancel\" with icon caution)")
        guard c == "Reset everything" else { return }

        // Wine is shared with any other Windows app you run, so never remove it
        // silently. If WE installed it for SAI we say so and default to removing;
        // otherwise we default to keeping it.
        var removeWine = false
        if hadWine {
            let q = ours
                ? "Also remove Wine?\n\nThis app installed Wine Staging for SAI, so removing it should be safe. It goes to the Trash and you can reinstall it from this window anytime."
                : "Also remove Wine?\n\nWine Staging was NOT installed by this app — you may be using it for other Windows programs. Keeping it is the safe choice."
            let def = ours ? "Move Wine to Trash" : "Keep Wine"
            let w = osa("button returned of (display dialog \(q.debugDescription) buttons {\"Keep Wine\", \"Move Wine to Trash\"} default button \(def.debugDescription) with icon caution)")
            removeWine = (w == "Move Wine to Trash")
        }

        // --- wipe -------------------------------------------------------------
        try? FileManager.default.removeItem(atPath: appPrefix)
        try? FileManager.default.removeItem(atPath: appSupport() + "/config.txt")
        try? FileManager.default.removeItem(atPath: appSupport() + "/installed-src.txt")
        if removeWine {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: "/Applications/Wine Staging.app"), resultingItemURL: nil)
            try? FileManager.default.removeItem(atPath: appSupport() + "/wine-ours.txt")
        }
        refresh()

        if removeWine || wineBin() == nil {
            alertUser("Reset done. Everything was removed.\n\nInstall Wine again from this window, then pick your SAI folder and Launch — your license is saved and will be restored automatically.")
            return
        }
        // --- rebuild ----------------------------------------------------------
        chooseSAI()                                   // forgotten on purpose: ask again
        guard savedSAIPath() != nil else {
            alertUser("Reset done. Choose your SAI folder in this window whenever you're ready — your license is saved and will be restored.")
            return
        }
        doReinstall(mode: .rebuild)
    }

    // ---- in-app Wine install with live progress -----------------------------
    // install-wine.sh needs no sudo (it only writes to /Applications), so we can
    // run it as a child process and show curl's progress in the window instead
    // of sending the user to a Terminal and hoping they watch it. Terminal
    // remains the fallback if the bundled script is missing or the run fails.
    var wineRow: NSStackView!
    var wineBar: PressureBar!
    var wineLabel: NSTextField!
    var wineProc: Process?
    var wineOutBuf = ""

    /// Pull the last "NN.N%" out of a curl progress-bar chunk.
    func percent(in s: String) -> Double? {
        guard let pctIdx = s.lastIndex(of: "%") else { return nil }
        var digits = ""
        var i = pctIdx
        while i > s.startIndex {
            i = s.index(before: i)
            let c = s[i]
            if c.isNumber || c == "." { digits.insert(c, at: digits.startIndex) } else { break }
        }
        return Double(digits)
    }

    func handleWineLine(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        DispatchQueue.main.async {
            if let p = self.percent(in: t), t.contains("#") || t.hasSuffix("%") {
                self.wineBar.value = CGFloat(p / 100.0)
                self.wineLabel.stringValue = String(format: "Downloading Wine… %.1f%%", p)
            } else if t.contains("Extracting") {
                self.wineBar.value = 1; self.wineLabel.stringValue = "Extracting…"
            } else if t.contains("Installing to") {
                self.wineLabel.stringValue = "Installing to /Applications…"
            } else if t.contains("Finding the latest") {
                self.wineLabel.stringValue = "Finding the latest Wine build…"
            } else if t.contains("Done!") {
                self.wineLabel.stringValue = "Wine installed."
            }
        }
    }

    @objc func installWineInApp() {
        guard wineProc == nil else { return }
        guard let sh = Bundle.main.resourcePath.map({ "\($0)/install-wine.sh" }),
              FileManager.default.fileExists(atPath: sh) else {
            installWineViaTerminal(); return
        }
        markWineInstalledByUs()
        wineRow.isHidden = false
        wineBar.value = 0
        wineLabel.stringValue = "Starting…"
        applyLayout()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [sh]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        wineOutBuf = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self = self else { return }
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self.wineOutBuf += s
            // curl redraws its bar with \r, so split on BOTH terminators and treat
            // the trailing partial chunk as a live progress line.
            let parts = self.wineOutBuf.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            self.wineOutBuf = parts.last ?? ""
            for l in parts.dropLast() { self.handleWineLine(l) }
            self.handleWineLine(self.wineOutBuf)
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.wineProc = nil
                let ok = wineBin() != nil
                self.wineLabel.stringValue = ok ? "Wine installed ✅" : "Wine install failed — try the Terminal fallback."
                self.wineBar.value = ok ? 1 : 0
                self.refresh()
                if !ok {
                    let c = osa("button returned of (display dialog \"The automatic Wine install didn't finish.\n\nRun it in a Terminal window instead so you can see the full output?\" buttons {\"Cancel\", \"Open Terminal\"} default button \"Open Terminal\" with icon caution)")
                    if c == "Open Terminal" { installWineViaTerminal() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.wineRow.isHidden = true; self.applyLayout()
                    }
                }
            }
        }
        do { try p.run(); wineProc = p } catch {
            wineRow.isHidden = true; installWineViaTerminal()
        }
    }

    // ---- automatic setup ----------------------------------------------------
    // Walks every required step in order and does each one itself, pausing only
    // where macOS or a licence genuinely needs a human. Replaces "read five rows,
    // work out which button to press, repeat".
    @objc func autoSetup() {
        guard !autoRunning else { return }
        autoRunning = true
        autoBtn.isEnabled = false
        DispatchQueue.global().async { self.autoSteps() }
    }

    func step(_ n: Int, _ msg: String) {
        DispatchQueue.main.async { self.subtitle.stringValue = "Step \(n)/5 — \(msg)" }
    }
    /// Run a main-thread UI call from the background and wait for its result.
    func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        var out: T!
        DispatchQueue.main.sync { out = work() }
        return out
    }

    func autoSteps() {
        defer { DispatchQueue.main.async { self.autoRunning = false; self.autoBtn.isEnabled = true; self.refresh() } }

        // 1 — Wine
        if wineBin() == nil {
            step(1, "installing Wine…")
            let go = onMain { osa("button returned of (display dialog \"Automatic setup will now install Wine.\n\nIt's about a 300 MB download and runs in a Terminal window so you can watch the progress. I'll wait for it and carry on by myself when it's done.\" buttons {\"Cancel\", \"Install Wine\"} default button \"Install Wine\" with icon note)") }
            guard go == "Install Wine" else { return }
            onMain { self.markWineInstalledByUs() }
            installWineViaTerminal()
            // wait for Wine to appear (up to 20 min — it's a big download)
            var waited = 0
            while wineBin() == nil && waited < 1200 {
                Thread.sleep(forTimeInterval: 2); waited += 2
                if waited % 20 == 0 { step(1, "waiting for Wine to finish installing… (\(waited)s)") }
            }
            guard wineBin() != nil else {
                onMain { alertUser("Wine still isn't in /Applications, so automatic setup stopped here.\n\nFinish the Wine install in the Terminal window, then press 'Set up everything automatically' again — it will pick up from this step.") }
                return
            }
        }
        guard let wine = wineBin() else { return }

        // 2 — SAI source folder
        if savedSAIPath() == nil {
            step(2, "finding your SAI folder…")
            let found = onMain { self.findSAIFolders() }
            if found.count == 1 {
                let c = onMain { osa("button returned of (display dialog \"Found SAI here:\n\n\((found[0] as NSString).abbreviatingWithTildeInPath)\n\nUse this folder?\" buttons {\"Choose another…\", \"Use this folder\"} default button \"Use this folder\" with icon note)") }
                if c == "Use this folder" { onMain { saveSAIPath(found[0]) } } else { onMain { self.chooseSAI() } }
            } else {
                onMain { self.chooseSAI() }
            }
            guard savedSAIPath() != nil else {
                onMain { alertUser("Automatic setup stopped: no SAI folder chosen.\n\nRun it again whenever you're ready — it resumes from here.") }
                return
            }
        }
        guard let src = savedSAIPath() else { return }

        // 3 — build the prefix
        if !saiInstalledInPrefix() || prefixIsStale() {
            step(3, "building the Wine prefix and copying SAI… (about a minute)")
            guard performSetup(src, wine, mode: .ensure, quiet: true) else {
                onMain { alertUser("Automatic setup couldn't build the Wine prefix. Check the SAI folder and try again.") }
                return
            }
        }

        // 4 — licence
        if installedLicenseName() == nil {
            step(4, "installing your license…")
            let c = onMain { osa("button returned of (display dialog \"Do you have your SAI license file (.slc)?\n\nSAI runs and draws without it, but can't save. Licenses come from SYSTEMAX — this project is not affiliated with them and cannot provide one.\" buttons {\"Skip for now\", \"Open official site\", \"I have my .slc\"} default button \"I have my .slc\" with icon note)") }
            if c == "Open official site" { onMain { self.openOfficialSAISite() } }
            else if c == "I have my .slc" { onMain { self.chooseLicense() } }
        }

        // 5 — permission
        if !inputMonitoringGranted() {
            step(5, "granting Input Monitoring…")
            onMain { self.grantInputMonitoring() }
            var waited = 0
            while !inputMonitoringGranted() && waited < 180 {
                Thread.sleep(forTimeInterval: 2); waited += 2
            }
        }

        // done
        let ok = wineBin() != nil && saiInstalledInPrefix() && inputMonitoringGranted()
        DispatchQueue.main.async {
            self.subtitle.stringValue = ok ? "All set. Click Launch." : "Almost there — finish the red items above."
            let lic = installedLicenseName() == nil ? "\n\nNo license installed yet — SAI will run but can't save." : ""
            alertUser(ok
                ? "Setup complete.\n\nSAI is installed in \((prefixSAIDir as NSString).abbreviatingWithTildeInPath).\(lic)\n\nClick \"Launch SAI with Pressure\", then in SAI turn on Others → Options → Pen Tablet → Use WinTab API and restart SAI."
                : "Automatic setup finished what it could. The remaining red items in the window need you.\(lic)")
        }
    }

    // Remove everything this project created, and NOTHING the user brought.
    // Their SAI source folder and their original .slc are never touched — those
    // are inputs we copied FROM, not things we own.
    @objc func uninstallEverything() {
        let fm = FileManager.default
        let src = savedSAIPath()
        let srcExists = src.map { fm.fileExists(atPath: "\($0)/sai2.exe") } ?? false
        let keptLine = srcExists
            ? "\n\nKEPT (yours, never touched):\n• \((src! as NSString).abbreviatingWithTildeInPath)"
            : "\n\nYour own SAI folder is never touched."
        let c = osa("button returned of (display dialog \"Remove SAI Pen Pressure's installation?\n\nWILL BE DELETED:\n• \(( appPrefix as NSString).abbreviatingWithTildeInPath) (Wine prefix + the SAI copy inside it)\n• saved settings: chosen folder, dev mode, recordings\(keptLine)\" buttons {\"Cancel\", \"Remove\"} default button \"Cancel\" with icon caution)")
        guard c == "Remove" else { return }

        // The licence is the one thing we cannot recreate — ask before dropping it.
        var keepLicense = true
        if !slcFiles(in: licenseStashDir()).isEmpty {
            let l = osa("button returned of (display dialog \"Keep your saved license copy?\n\nWe hold a copy of \(slcFiles(in: licenseStashDir()).joined(separator: ", ")) so a future reinstall can restore it. Your ORIGINAL .slc file wherever you downloaded it is never touched either way.\" buttons {\"Delete it too\", \"Keep license\"} default button \"Keep license\" with icon note)")
            keepLicense = (l != "Delete it too")
        }

        var removeWine = false
        if wineBin() != nil {
            let ours = wineInstalledByUs()
            let q = ours
                ? "Also remove Wine?\n\nThis app installed Wine Staging for SAI, so removing it should be safe."
                : "Also remove Wine?\n\nWine Staging was NOT installed by this app — you may use it for other Windows programs. Keeping it is the safe choice."
            let def = ours ? "Move Wine to Trash" : "Keep Wine"
            removeWine = (osa("button returned of (display dialog \(q.debugDescription) buttons {\"Keep Wine\", \"Move Wine to Trash\"} default button \(def.debugDescription) with icon caution)") == "Move Wine to Trash")
        }

        try? fm.removeItem(atPath: appPrefix)
        for f in ["config.txt", "installed-src.txt", "devmode.txt", "wine-ours.txt"] {
            try? fm.removeItem(atPath: appSupport() + "/" + f)
        }
        try? fm.removeItem(atPath: appSupport() + "/recordings")
        try? fm.removeItem(atPath: appSupport() + "/bin")
        if !keepLicense { try? fm.removeItem(atPath: licenseStashDir()) }
        if removeWine {
            try? fm.trashItem(at: URL(fileURLWithPath: "/Applications/Wine Staging.app"), resultingItemURL: nil)
        }
        devMode = false
        refresh()
        let licNote = keepLicense && !slcFiles(in: licenseStashDir()).isEmpty
            ? "\n\nYour license copy was kept and will be restored on the next install."
            : ""
        alertUser("Removed.\(licNote)\n\nThis app itself is still here — quit it and drag it to the Trash if you're done, or just pick your SAI folder again to reinstall.")
    }

    /// Did THIS app install Wine? Set when the user takes our "Install Wine"
    /// path, so a reset can tell "installed for SAI" from "the user's own Wine".
    func wineInstalledByUs() -> Bool {
        FileManager.default.fileExists(atPath: appSupport() + "/wine-ours.txt")
    }
    func markWineInstalledByUs() {
        try? "1".write(toFile: appSupport() + "/wine-ours.txt", atomically: true, encoding: .utf8)
    }

    func doReinstall(mode: SetupMode) {
        guard let wine = wineBin(), let src = savedSAIPath() else { refresh(); return }
        let wasRunning = running
        subtitle.stringValue = mode == .rebuild ? "Rebuilding the Wine prefix…" : "Reinstalling SAI…"
        launchBtn.isEnabled = false
        // wineboot + a full copy takes ~a minute; off the main thread so the
        // window keeps drawing instead of beachballing.
        DispatchQueue.global().async {
            let ok = performSetup(src, wine, mode: mode)
            DispatchQueue.main.async {
                self.running = wasRunning
                self.refresh()
                if ok {
                    let lic = installedLicenseName().map { "\n\nLicense in place: \($0)" }
                        ?? "\n\nNo license found — use Install… on the license row if you need to save."
                    alertUser("Done. SAI is installed in:\n\n\(( prefixSAIDir as NSString).abbreviatingWithTildeInPath)\(lic)")
                } else {
                    self.subtitle.stringValue = "Reinstall failed — check the SAI source folder."
                }
            }
        }
    }

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
    @objc func toggleDevMode(_ sender: NSMenuItem) { devMode.toggle() }

    func openPath(_ p: String, createIfMissing: Bool = false) {
        if !FileManager.default.fileExists(atPath: p) {
            guard createIfMissing else { alertUser("Nothing there yet:\n\n\(p)"); return }
            try? "".write(toFile: p, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
    @objc func openHelperLog() { openPath("\(appPrefix)/helper.log") }
    @objc func openWakeLog()   { openPath("/tmp/sai-wake.log") }
    @objc func openDLLLog()    { openPath("\(appPrefix)/drive_c/wtlog.txt") }
    @objc func revealPrefix() {
        NSWorkspace.shared.selectFile(prefixSAIExe, inFileViewerRootedAtPath: appPrefix)
    }
    // Three explicit folders instead of one ambiguous "Prefix" that opened a
    // Finder window with sai2.exe selected and left you guessing what you were
    // looking at.
    @objc func openSAIInWine()   { openFolder(prefixSAIDir) }     // the copy that RUNS
    /// Reveal the certificate itself, so "where did it actually go?" is one click.
    @objc func revealLicense() {
        guard let name = installedLicenseName(), let dir = licenseLocations().first else {
            alertUser("No license installed yet.\n\nUse Install… on the SAI license row — licenses come from SYSTEMAX, this app can't provide one.")
            return
        }
        NSWorkspace.shared.selectFile("\(dir)/\(name)", inFileViewerRootedAtPath: dir)
    }
    @objc func openWinePrefix()  { openFolder(appPrefix) }        // the whole bottle
    @objc func openAppSupport()  { openFolder(appSupport()) }     // config, licence stash, recordings
    func openFolder(_ p: String) {
        guard FileManager.default.fileExists(atPath: p) else { alertUser("That folder doesn't exist yet:\n\n\(p)"); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    // ---- health check -------------------------------------------------------
    // Verifies every moving part is actually where it has to be. This is the
    // check that would have answered "I removed some files and nothing works"
    // in one click instead of a debugging session.
    func runCapture(_ exe: String, _ args: [String], env: [String: String] = [:]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        if !env.isEmpty { var e = ProcessInfo.processInfo.environment; env.forEach { e[$0] = $1 }; p.environment = e }
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    @objc func healthCheckTapped() {
        console.string = "Running health check… (querying the Wine registry, a few seconds)"
        subtitle.stringValue = "Running health check…"
        DispatchQueue.global().async {
            let report = self.buildHealthReport()
            DispatchQueue.main.async {
                self.console.string = report
                self.console.scrollToEndOfDocument(nil)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                self.subtitle.stringValue = "Health check done — copied to clipboard."
            }
        }
    }

    func buildHealthReport() -> String {
        let fm = FileManager.default
        var lines: [String] = ["=== SAI Pen Pressure — health check ===",
                               "version \(currentVersion())", ""]
        var problems = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "", fatal: Bool = true) {
            if !ok && fatal { problems += 1 }
            let mark = ok ? "OK  " : (fatal ? "FAIL" : "warn")
            lines.append("[\(mark)] \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        // --- Wine
        let wine = wineBin()
        check("Wine runtime", wine != nil, wine ?? "not found in /Applications or $WINE")

        // --- source folder
        let src = savedSAIPath()
        check("SAI source folder recorded", src != nil, src ?? "none chosen")
        if let s = src {
            check("SAI source still exists", fm.fileExists(atPath: "\(s)/sai2.exe"),
                  fm.fileExists(atPath: "\(s)/sai2.exe") ? s : "missing sai2.exe at \(s)", fatal: false)
        }

        // --- prefix layout
        check("Wine prefix exists", fm.fileExists(atPath: appPrefix), appPrefix)
        check("drive_c exists", fm.fileExists(atPath: "\(appPrefix)/drive_c"))
        check("SAI2 folder in prefix", fm.fileExists(atPath: prefixSAIDir), prefixSAIDir)
        let exeAttrs = try? fm.attributesOfItem(atPath: prefixSAIExe)
        let exeSize = (exeAttrs?[.size] as? Int) ?? 0
        check("sai2.exe installed", saiInstalledInPrefix(),
              exeSize > 0 ? "\(exeSize / 1024 / 1024) MB" : "missing")
        check("install matches selected source", !prefixIsStale(),
              prefixIsStale() ? "prefix was built from: \(installedSrcPath() ?? "unknown")" : "")

        // --- the bridge
        let sysDLL = "\(appPrefix)/drive_c/windows/system32/wintab32.dll"
        check("wintab32.dll in system32", fm.fileExists(atPath: sysDLL), sysDLL)
        if let res = Bundle.main.resourcePath {
            let a = fm.contents(atPath: "\(res)/wintab32.dll")
            let b = fm.contents(atPath: sysDLL)
            if let a = a, let b = b {
                check("wintab32.dll matches this build", a == b,
                      a == b ? "" : "installed DLL differs from the one shipped in this app — Reinstall to fix", fatal: false)
            }
        }

        // --- registry
        if let w = wine {
            let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
            let ov = runCapture(w, ["reg", "query", "HKCU\\Software\\Wine\\DllOverrides", "/v", "wintab32"], env: env)
            check("DllOverrides wintab32 = native,builtin", ov.contains("native,builtin"),
                  ov.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "key not set" : "")
            let cmd = runCapture(w, ["reg", "query", "HKCU\\Software\\Wine\\Mac Driver", "/v", "LeftCommandIsCtrl"], env: env)
            check("Cmd→Ctrl remap (LeftCommandIsCtrl=Y)", cmd.uppercased().contains("Y"),
                  "", fatal: false)
        }

        // --- licence + runtime files
        check("license (.slc) in prefix", installedLicenseName() != nil,
              installedLicenseName() ?? "none — SAI can draw but not save", fatal: false)
        check("stashed license backup", !slcFiles(in: licenseStashDir()).isEmpty,
              slcFiles(in: licenseStashDir()).joined(separator: ", "), fatal: false)
        check("pressure file", fm.fileExists(atPath: "\(appPrefix)/drive_c/wt_pressure.txt"),
              "", fatal: false)

        // --- permission
        check("Input Monitoring granted", inputMonitoringGranted(),
              inputMonitoringGranted() ? "" : "System Settings → Privacy & Security → Input Monitoring")

        lines.append("")
        lines.append(problems == 0
            ? "RESULT: everything checks out."
            : "RESULT: \(problems) problem\(problems == 1 ? "" : "s") found. 'Install from scratch' fixes most of them.")
        return lines.joined(separator: "\n")
    }

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

    func wakeLogLineCount() -> Int {
        guard let s = try? String(contentsOfFile: "/tmp/sai-wake.log", encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").count
    }

    @objc func toggleRecord() {
        if recording != nil { stopRecording(); return }
        _ = startPressureEngineOnce()      // so pen counters actually move
        recMaxPressure = 0; recPressSamples = 0
        recording = RecSnapshot(t: Date(), seq: seq, tabletPtr: g_evTabletPtr,
                                tabletMouse: g_evTabletMouse, prox: g_evProx,
                                plainMouse: g_evPlainMouse, wakeLines: wakeLogLineCount())
        recBtn.title = "■ Stop recording"
        console.string = "● Recording… reproduce the problem now, then press Stop."
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.recording != nil else { return }
            let p = max(0, lastKeyP)
            if p > 0 { self.recPressSamples += 1 }
            if p > self.recMaxPressure { self.recMaxPressure = p }
        }
        RunLoop.main.add(t, forMode: .common)
        recTimer = t
        wlog("=== RECORDING STARTED ===")
    }

    func stopRecording() {
        guard let r = recording else { return }
        wlog("=== RECORDING STOPPED ===")
        recTimer?.invalidate(); recTimer = nil
        recording = nil
        recBtn.title = "● Record session"

        let dur = Date().timeIntervalSince(r.t)
        // only the wake-log lines written during the window
        var newLines: [String] = []
        if let s = try? String(contentsOfFile: "/tmp/sai-wake.log", encoding: .utf8) {
            newLines = s.split(separator: "\n").map(String.init).dropFirst(r.wakeLines).map { $0 }
        }
        let win = g_saiWindow.isEmpty ? "none on screen"
            : "\(Int(g_saiWindow.width))x\(Int(g_saiWindow.height)) at (\(Int(g_saiWindow.minX)),\(Int(g_saiWindow.minY)))"
        let pct = Int((Double(recMaxPressure) / Double(PressureCore.maxPressure) * 100).rounded())
        var out = """
        === SAI Pen Pressure — session recording ===
        version   \(currentVersion())      duration  \(String(format: "%.1fs", dur))
        started   \(r.t)

        --- pen ---
        samples streamed to SAI   \(seq - r.seq)
        tablet pointer events     \(g_evTabletPtr - r.tabletPtr)
        tablet-mouse events       \(g_evTabletMouse - r.tabletMouse)
        proximity changes         \(g_evProx - r.prox)
        PLAIN mouse events        \(g_evPlainMouse - r.plainMouse)
        max pressure              \(recMaxPressure)/\(PressureCore.maxPressure) (\(pct)%)
        frames with pen down      \(recPressSamples)
        pen seen this session     \(g_penEverSeen)

        --- SAI ---
        window                    \(win)
        menu strip active         \(!g_saiStrip.isEmpty)
        auto-wake enabled         \(autoWake)

        --- setup ---
        prefix                    \(appPrefix)
        sai2.exe installed        \(saiInstalledInPrefix())
        prefix stale              \(prefixIsStale())
        license                   \(installedLicenseName() ?? "none")
        Input Monitoring          \(inputMonitoringGranted())

        --- wake log during recording (\(newLines.count) lines) ---
        """
        out += "\n" + (newLines.isEmpty ? "(nothing — no wake/auto-wake fired)" : newLines.joined(separator: "\n"))

        // interpretation, so the numbers mean something without reading the code
        var notes: [String] = []
        if seq - r.seq == 0 { notes.append("• No pen samples reached SAI. Either the pen wasn't used, or Input Monitoring is off.") }
        if g_evPlainMouse - r.plainMouse > 0 && g_evTabletMouse - r.tabletMouse == 0 && g_penEverSeen {
            notes.append("• Pen arrived as a PLAIN mouse — the Wacom driver demoted it. That's the app-switch freeze signature (issue #2).")
        }
        if recMaxPressure == 0 && seq - r.seq > 0 { notes.append("• Samples flowed but pressure never exceeded 0 — hover only, no contact.") }
        if !newLines.isEmpty { notes.append("• Wake activity fired during this window (see above).") }
        if !notes.isEmpty { out += "\n\n--- notes ---\n" + notes.joined(separator: "\n") }

        console.string = out
        console.scrollToEndOfDocument(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)

        let dir = appSupport() + "/recordings"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let path = "\(dir)/session-\(f.string(from: r.t).replacingOccurrences(of: ":", with: "-")).log"
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        subtitle.stringValue = "Recording saved + copied to clipboard."
    }
    @objc func copyDiagnostics() {
        let fm = FileManager.default
        var os = ProcessInfo.processInfo.operatingSystemVersionString
        os = os.replacingOccurrences(of: "Version ", with: "")
        let lines = [
            "SAI Pen Pressure \(currentVersion())",
            "macOS: \(os)",
            "Wine: \(wineBin() ?? "NOT FOUND")",
            "Prefix: \(appPrefix)  (exists: \(fm.fileExists(atPath: appPrefix)))",
            "SAI source: \(savedSAIPath() ?? "none")",
            "SAI installed from: \(installedSrcPath() ?? "unknown")",
            "sai2.exe in prefix: \(saiInstalledInPrefix())",
            "prefix stale: \(prefixIsStale())",
            "license: \(installedLicenseName() ?? "none")",
            "wintab32.dll: \(fm.fileExists(atPath: "\(appPrefix)/drive_c/windows/system32/wintab32.dll"))",
            "Input Monitoring: \(inputMonitoringGranted())",
            "auto-wake: \(autoWake)",
        ]
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        alertUser("Diagnostics copied to the clipboard:\n\n\(text)")
    }

    // Uninstall Wine on request: move "Wine Staging.app" to the Trash (reversible)
    // after confirming. Deliberately leaves the Wine prefix (~/SAI2-pressure) and
    // its SAI setup + license .slc untouched — only the Wine runtime is removed.
    func uninstallWine() {
        let path = "/Applications/Wine Staging.app"
        guard FileManager.default.fileExists(atPath: path) else {
            alertUser("Wine Staging isn't in /Applications, so there's nothing to uninstall.")
            refresh(); return
        }
        let choice = osa("button returned of (display dialog \"Move 'Wine Staging.app' to the Trash?\n\nThis removes the Wine runtime. Your SAI setup and license (in ~/SAI2-pressure) are kept, and you can reinstall Wine anytime from this window.\" buttons {\"Cancel\", \"Move to Trash\"} default button \"Cancel\" with icon caution)")
        guard choice == "Move to Trash" else { refresh(); return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            alertUser("Wine was moved to the Trash. Reopen this window's Install Wine option whenever you want it back.")
        } catch {
            alertUser("Couldn't remove Wine automatically. Drag 'Wine Staging.app' from /Applications to the Trash yourself.\n\n(\(error.localizedDescription))")
        }
        refresh()
    }

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
        testBtn.title = "Stop Test"
        testHint.isHidden = false; barRow.isHidden = false
        // fast (~60fps), .common-mode timer so the bar tracks the pen instantly and
        // keeps updating even while the window is being interacted with. The bar is
        // custom-drawn (no easing), so it jumps to the real value like the % does.
        let t = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let p = max(0, lastKeyP)                 // lastKeyP is -1 until a pen is first seen
            self.pressureBar.value = CGFloat(p) / CGFloat(PressureCore.maxPressure)
            self.pressureLabel.stringValue = "\(Int((Double(p) / Double(PressureCore.maxPressure) * 100).rounded()))%"
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

    func relaunchForPermission() {
        // Tap couldn't be created — Input Monitoring isn't (yet) granted to THIS
        // app build. Guide the user to grant it, open the right Settings pane,
        // and reopen the app (macOS applies the grant on a fresh launch).
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        _ = osa("display dialog \"Couldn't read the tablet yet.\n\nIn System Settings → Privacy & Security → Input Monitoring, turn ON 'SAI Pen Pressure', then reopen this app.\" buttons {\"Reopen now\"} default button \"Reopen now\" with icon caution")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 1; open '\(Bundle.main.bundlePath)'"]
        try? p.run()
        exit(0)
    }
}

let g_setup = SetupController()     // strong ref (NSApplication.delegate is weak)
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.regular)
nsApp.delegate = g_setup
nsApp.run()

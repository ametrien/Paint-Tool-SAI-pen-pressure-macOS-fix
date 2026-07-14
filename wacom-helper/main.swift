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

// Optional diagnostic log for the "wake SAI" feature. Off unless WT_WAKELOG is
// set, so the release doesn't write to /tmp on every keypress.
let wakeLogOn = ProcessInfo.processInfo.environment["WT_WAKELOG"] != nil
func wlog(_ s: String) {
    guard wakeLogOn else { return }
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
func ensureSetup(_ saiSrc: String, _ wine: String) -> Bool {
    let saiExe = "\(appPrefix)/drive_c/SAI2/sai2.exe"
    if FileManager.default.fileExists(atPath: saiExe) { return true }        // already set up
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
    alertUser("Setting up SAI for the first time — this takes about a minute after you click OK. Please wait for SAI to appear.")
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    runProc(wine, ["wineboot", "-u"], env: env)
    let dst = "\(appPrefix)/drive_c/SAI2"
    try? FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
    runProc("/bin/cp", ["-R", "\(saiSrc)/.", dst])
    guard FileManager.default.fileExists(atPath: saiExe) else {
        alertUser("Something went wrong copying SAI into the Wine prefix. Check that you have free disk space and that the SAI folder is readable, then reopen the app and try again."); return false
    }
    if let res = Bundle.main.resourcePath {
        let sys = "\(appPrefix)/drive_c/windows/system32"
        try? FileManager.default.createDirectory(atPath: sys, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: "\(sys)/wintab32.dll")
        try? FileManager.default.copyItem(atPath: "\(res)/wintab32.dll", toPath: "\(sys)/wintab32.dll")
    }
    runProc(wine, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "wintab32",
                   "/t", "REG_SZ", "/d", "native,builtin", "/f"], env: env)
    return FileManager.default.fileExists(atPath: saiExe)
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

// LAUNCH (runs only after the pressure tap is active): start SAI; quit the app
// when SAI closes.
func launchSAIApp() {
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
        try? "0".write(toFile: pf, atomically: true, encoding: .ascii); exit(0)
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

func emit(pressure: Int, loc: CGPoint) {
    // coordinate mapping + clamp + dedup rules live in PressureCore (unit-tested)
    let p = PressureCore.clampPressure(pressure)
    // WT_NO_HOVER experiment: drop hover samples (p==0) unless they END a
    // stroke (previous sample was a press) — see the flag's comment up top.
    if noHover && p == 0 && lastKeyP <= 0 { return }
    let (xf, yf) = PressureCore.mapToVirtual(locX: loc.x, locY: loc.y, vX: vX, vY: vY, vH: vH)
    if PressureCore.isDuplicate(p: p, xf: xf, yf: yf, lastP: lastKeyP, lastX: lastKeyX, lastY: lastKeyY) { return }
    lastKeyP = p; lastKeyX = xf; lastKeyY = yf
    send(p, xf, yf)
    if verbose && (seq % 100 == 1 || p == 0) {
        print("captured=\(seq) pressure=\(p)/1023")
    }
}

// resend the last sample (keepalive) — keeps SAI's "pen present" state alive
// during a HOVER with no movement, so the OS cursor stays hidden. ONLY when the
// last sample was pen-up/hover (lastKeyP == 0): re-sending an actual press
// (lastKeyP > 0) made SAI register spurious extra clicks / feel glitchy.
func keepAlive() {
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
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
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
        // pen entering/leaving range drives the keepalive (arrow stays hidden
        // while present, mouse can paint once the pen leaves)
        inProximity = event.getIntegerValueField(.tabletProximityEventEnterProximity) != 0
        if !inProximity { emit(pressure: 0, loc: event.location) }
    case .tabletPointer:
        inProximity = true
        let pr = event.getDoubleValueField(.tabletEventPointPressure)
        emit(pressure: Int(pr * 1023.0), loc: event.location)
    case .leftMouseUp:
        if isTabletMouse(event) { emit(pressure: 0, loc: event.location) }   // pen tip lift (still hovering)
    case .mouseMoved, .leftMouseDown, .leftMouseDragged:
        if isTabletMouse(event) {
            inProximity = true
            let pr = event.getDoubleValueField(.tabletEventPointPressure)
            emit(pressure: Int(pr * 1023.0), loc: event.location)
        } else {
            inProximity = false   // real mouse/trackpad -> pen not in use, let SAI have the mouse
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
// Returns false if the tablet tap can't be created (permission missing). ------
func startPressureEngine() -> Bool {
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
    }
    var reqs: [Req] = []
    var window: NSWindow!
    var subtitle: NSTextField!
    var launchBtn: NSButton!
    var statusFields: [NSTextField] = []
    var detailFields: [NSTextField] = []
    var fixButtons: [NSButton] = []
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
                    if wineBin() == nil { installWineViaTerminal() } else { self?.uninstallWine() }
                }, required: true,
                keepButton: true, keepButtonTitle: "Uninstall…"),
            Req(title: "PaintTool SAI folder", detail: "No folder chosen yet — click Choose.", fixTitle: "Choose…",
                ok: { saiReady() }, fix: { [weak self] in self?.chooseSAI() }, required: true,
                dynamicDetail: { savedSAIPath().map { "Using: \(($0 as NSString).abbreviatingWithTildeInPath)" }
                                 ?? "No folder chosen yet — click Choose." },
                keepButton: true),
            Req(title: "Input Monitoring permission", detail: "lets the app read your tablet's pressure", fixTitle: "Grant…",
                ok: { inputMonitoringGranted() }, fix: { requestInputMonitoring() }, required: true),
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
    }

    var lastReactivate = Date.distantPast
    @objc func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let hay = "\(app.bundleIdentifier ?? "") \(app.localizedName ?? "") \(app.executableURL?.path ?? "")".lowercased()
        guard hay.contains("wine") || hay.contains("sai") else { return }
        // throttle so we don't fight a normal activation into a loop
        guard Date().timeIntervalSince(lastReactivate) > 0.5 else { return }
        lastReactivate = Date()
        // a moment later, force ALL of Wine's windows fully forward/key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            app.activate(options: [.activateAllWindows])
        }
    }

    var statusItem: NSStatusItem?
    func setUpStatusItem() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        si.button?.title = "🖊"
        si.button?.toolTip = "SAI Pen Pressure"
        let menu = NSMenu()
        let wake = NSMenuItem(title: "Wake SAI window (if stuck)   ⌃⌥⌘Space", action: #selector(wakeSAI), keyEquivalent: "")
        wake.target = self
        menu.addItem(wake)
        let show = NSMenuItem(title: "Open Setup window", action: #selector(showSetupWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        si.menu = menu
        statusItem = si
    }

    @objc func showSetupWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ note: Notification) { refresh() }   // re-check when refocused

    func buildWindow() {
        let content = NSStackView()
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(lbl("SAI Pen Pressure Setup", 18, bold: true))
        subtitle = lbl("Let's get everything ready.", 12, color: .secondaryLabelColor)
        content.addArrangedSubview(subtitle)

        for (i, r) in reqs.enumerated() {
            let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
            let status = lbl("…", 15, bold: true)
            status.widthAnchor.constraint(equalToConstant: 22).isActive = true
            statusFields.append(status)
            let col = NSStackView(); col.orientation = .vertical; col.alignment = .leading; col.spacing = 1
            col.addArrangedSubview(lbl(r.title, 13, bold: true))
            let detail = lbl(r.detail, 11, color: .secondaryLabelColor)
            detailFields.append(detail)
            col.addArrangedSubview(detail)
            let btn = NSButton(title: r.fixTitle, target: self, action: #selector(fixTapped(_:)))
            btn.tag = i; btn.bezelStyle = .rounded
            btn.setContentHuggingPriority(.required, for: .horizontal)
            fixButtons.append(btn)
            let spacer = NSView()
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
            row.addArrangedSubview(status); row.addArrangedSubview(col); row.addArrangedSubview(spacer); row.addArrangedSubview(btn)
            row.widthAnchor.constraint(equalToConstant: 472).isActive = true
            content.addArrangedSubview(row)
        }

        // --- Test tablet pressure (optional; confirm the pen before Launch) ---
        testBtn = NSButton(title: "Test Tablet Pressure", target: self, action: #selector(testTapped))
        testBtn.bezelStyle = .rounded
        content.addArrangedSubview(testBtn)
        testHint = lbl("Now press your pen on the tablet — the bar should move.", 11, color: .secondaryLabelColor)
        testHint.isHidden = true
        content.addArrangedSubview(testHint)
        barRow = NSStackView(); barRow.orientation = .horizontal; barRow.alignment = .centerY; barRow.spacing = 10
        pressureBar = PressureBar()
        pressureBar.widthAnchor.constraint(equalToConstant: 240).isActive = true
        pressureBar.heightAnchor.constraint(equalToConstant: 14).isActive = true
        pressureLabel = lbl("0%", 12, bold: true)
        pressureLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        barRow.addArrangedSubview(pressureBar); barRow.addArrangedSubview(pressureLabel)
        barRow.isHidden = true
        content.addArrangedSubview(barRow)

        launchBtn = NSButton(title: "Launch SAI with Pressure", target: self, action: #selector(launchTapped))
        launchBtn.bezelStyle = .rounded; launchBtn.keyEquivalent = "\r"; launchBtn.controlSize = .large
        content.addArrangedSubview(launchBtn)

        // Rescue button (mirrors the menu-bar "🖊 → Wake SAI"): if SAI comes back
        // stuck/greyed after an app switch, force a full re-activation.
        let wakeBtn = NSButton(title: "Wake SAI window (if stuck)", target: self, action: #selector(wakeSAI))
        wakeBtn.bezelStyle = .rounded
        content.addArrangedSubview(wakeBtn)
        content.addArrangedSubview(lbl("Also on the 🖊 menu-bar icon, or press ⌃⌥⌘Space (Control-Option-Command-Space) anytime.", 10, color: .tertiaryLabelColor))

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SAI Pen Pressure"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        if running { return }
        for (i, r) in reqs.enumerated() {
            let ok = r.ok()
            statusFields[i].stringValue = ok ? "✅" : (r.required ? "❌" : "⚪️")
            if let dd = r.dynamicDetail { detailFields[i].stringValue = dd() }   // e.g. show the chosen folder
            if r.keepButton {                       // stays visible so you can change/uninstall it
                fixButtons[i].isHidden = false
                fixButtons[i].title = ok ? r.keepButtonTitle : r.fixTitle
            } else {
                fixButtons[i].isHidden = ok
            }
        }
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

    @objc func fixTapped(_ sender: NSButton) {
        reqs[sender.tag].fix()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func chooseSAI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Choose"; panel.message = "Select your SAI Ver.2 folder (the one containing sai2.exe)"
        if panel.runModal() == .OK, let url = panel.url {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("sai2.exe").path) {
                saveSAIPath(url.path)
            } else {
                alertUser("That folder doesn't contain sai2.exe. Pick the folder that directly contains sai2.exe.")
            }
        }
        refresh()
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
            self.pressureBar.value = CGFloat(p) / 1023.0
            self.pressureLabel.stringValue = "\(Int((Double(p) / 1023.0 * 100).rounded()))%"
        }
        RunLoop.main.add(t, forMode: .common)
        testTimer = t
    }

    func stopTest() {
        testing = false
        testTimer?.invalidate(); testTimer = nil
        if testBtn != nil { testBtn.title = "Test Tablet Pressure" }
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

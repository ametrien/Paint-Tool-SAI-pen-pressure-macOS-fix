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

// Is any SAI/Wine window still on screen? Used to decide when SAI has really
// closed (see launchSAIApp's terminationHandler).
func saiWindowIsOpen() -> Bool {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list {
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        guard owner.contains("wine") || owner.contains("sai") else { continue }
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
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        guard owner.contains("wine") || owner.contains("sai") else { continue }
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

    if PressureCore.isDuplicate(p: p, xf: xf, yf: yf, lastP: lastKeyP, lastX: lastKeyX, lastY: lastKeyY) { return }
    lastKeyP = p; lastKeyX = xf; lastKeyY = yf
    if p > 0 { g_lastDrawAt = Date() }        // "SAI is clearly alive" signal for auto-wake
    send(p, xf, yf)
    if verbose && (seq % 100 == 1 || p == 0) {
        print("captured=\(seq) pressure=\(p)/1023")
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
        emit(pressure: Int(pr * 1023.0), loc: event.location)
    case .leftMouseUp:
        if isTabletMouse(event) { emit(pressure: 0, loc: event.location) }   // pen tip lift (still hovering)
    case .mouseMoved, .leftMouseDown, .leftMouseDragged:
        if isTabletMouse(event) {
            g_evTabletMouse += 1
            g_lastTabletEvAt = CFAbsoluteTimeGetCurrent(); g_penEverSeen = true
            inProximity = true
            let pr = event.getDoubleValueField(.tabletEventPointPressure)
            emit(pressure: Int(pr * 1023.0), loc: event.location)
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
        si.button?.title = "🖊"
        si.button?.toolTip = "SAI Pen Pressure"
        let menu = NSMenu()
        let wake = NSMenuItem(title: "Wake SAI window (if stuck)   ⌃⌥⌘Space", action: #selector(wakeSAI), keyEquivalent: "")
        wake.target = self
        menu.addItem(wake)
        let auto = NSMenuItem(title: "Auto-wake when returning to SAI", action: #selector(toggleAutoWake(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = autoWake ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
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

    // Right-click on our Dock icon (only visible before SAI is launched — see
    // hideFromDock()). Left-click focuses SAI; the useful actions live here.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let wake = NSMenuItem(title: "Wake SAI window (if stuck)", action: #selector(wakeSAI), keyEquivalent: "")
        wake.target = self; m.addItem(wake)
        let setup = NSMenuItem(title: "Open Setup window", action: #selector(showSetupWindow), keyEquivalent: "")
        setup.target = self; m.addItem(setup)
        return m
    }


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

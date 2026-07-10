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
// Needs:  System Settings → Privacy & Security → Accessibility AND
//         Input Monitoring, both granted to the terminal that runs this.

import AppKit
import CoreGraphics
import Foundation

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

// ============================================================================
// APP-BUNDLE MODE — when launched as "SAI Pen Pressure.app" (with --app).
// First run: pick the SAI folder, create the Wine prefix, install our DLL.
// Every run: launch SAI alongside the pressure engine; quit when SAI closes.
// Run from a terminal WITHOUT --app and none of this happens (dev mode).
// Permissions (Accessibility / Input Monitoring) attach to the .app itself.
// ============================================================================
let isAppMode = CommandLine.arguments.contains("--app")
let appPrefix = NSString(string: "~/SAI2-pressure").expandingTildeInPath

func appSupport() -> String {
    let d = NSString(string: "~/Library/Application Support/SAIPenPressure").expandingTildeInPath
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
    alertUser("Setting up SAI for the first time — this takes about a minute after you click OK. Please wait for SAI to appear.")
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    runProc(wine, ["wineboot", "-u"], env: env)
    let dst = "\(appPrefix)/drive_c/SAI2"
    try? FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
    runProc("/bin/cp", ["-R", "\(saiSrc)/.", dst])
    guard FileManager.default.fileExists(atPath: saiExe) else {
        alertUser("Couldn't find sai2.exe in the folder you chose. Reopen the app and pick the folder that directly contains sai2.exe."); return false
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
        let choice = osa("button returned of (display dialog \"Wine isn't installed — SAI needs it to run.\n\nInstall it automatically now? (~300 MB download; you'll see progress in a Terminal window, then reopen this app.)\" buttons {\"Do it manually\", \"Install Wine\"} default button \"Install Wine\" with icon note)")
        if choice == "Install Wine", let sh = installer, FileManager.default.fileExists(atPath: sh) {
            _ = osa("tell application \"Terminal\" to do script \"bash '\(sh)'\"")
            _ = osa("tell application \"Terminal\" to activate")
            alertUser("Installing Wine in Terminal — watch the progress there. When it says it's done, just reopen SAI Pen Pressure.")
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

if isAppMode { runAppSetup() }   // SAI is launched later, after the tap succeeds (see below)

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
    var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
    for id in ids {
        let b = CGDisplayBounds(id)          // top-left global space, same as CGEvent.location
        minX = min(minX, Double(b.minX)); minY = min(minY, Double(b.minY))
        maxX = max(maxX, Double(b.maxX)); maxY = max(maxY, Double(b.maxY))
    }
    vX = minX; vY = minY; vW = maxX - minX; vH = maxY - minY
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
var gKeyTap: CFMachPort?
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
    let p = max(0, min(1023, pressure))
    // position RELATIVE to the virtual-desktop origin, flipped to bottom-left
    // y-up within the whole virtual desktop (matches the DLL's y-up convention).
    // 8x fixed-point preserves sub-pixel precision through the integer protocol.
    let xf = Int((loc.x - vX) * 8)
    let yf = Int(((vY + vH) - loc.y) * 8)
    // drop consecutive identical samples (also de-dups any doubled tap events)
    if p == lastKeyP && xf == lastKeyX && yf == lastKeyY { return }
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
    guard inProximity, lastKeyP == 0 else { return }
    if CFAbsoluteTimeGetCurrent() - lastSendMs > 0.05 {   // only if idle > 50ms
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

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let t = gTap { CGEvent.tapEnable(tap: t, enable: true) }
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

// ============================================================================
// Cmd -> Ctrl keybinding remap (Mac-friendliness layer)
// While SAI is the frontmost app, rewrite Cmd+<key> into Ctrl+<key> for the
// shortcuts SAI expects (SAI uses Windows Ctrl-based shortcuts). Everywhere
// else, and for keys not in the allowlist, events pass through untouched.
//
// TOGGLE (source, for now): set remapCmdToCtrl = false to disable entirely.
// Edit remapKeys to change which shortcuts are remapped.
// ============================================================================
let remapCmdToCtrl = true
let remapKeys: Set<Int64> = [
    6,   // Z  – undo
    16,  // Y  – redo
    7,   // X  – cut / swap colors
    8,   // C  – copy
    9,   // V  – paste
    0,   // A  – select all
    2,   // D  – deselect
    1,   // S  – save
    45,  // N  – new
    31,  // O  – open
    14,  // E
    17,  // T
    3,   // F
    5,   // G
    32,  // U
    33,  // [  – brush size down
    30,  // ]  – brush size up
]
// NOT remapped (stay as macOS shortcuts): Q/W/H/M (quit/close/hide/minimise),
// Tab/Space (app switch / Spotlight), comma, backtick, etc.

func isSAIFrontmost() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    let hay = [(app.bundleIdentifier ?? ""), (app.localizedName ?? ""),
               (app.executableURL?.path ?? "")].joined(separator: " ").lowercased()
    return hay.contains("wine") || hay.contains("sai")
}

let kVK_Command = Int64(55), kVK_RightCommand = Int64(54), kVK_Control = Int64(59)

let keyCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = gKeyTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    // The Cmd MODIFIER KEY itself, remapped to Control while SAI is frontmost —
    // so Wine sees a clean Control held (not the Windows key), and every
    // subsequent shortcut is a real Ctrl+<key>. Without this, Wine kept seeing
    // Cmd held and combined it with our rewritten key -> wrong shortcut.
    if type == .flagsChanged {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard remapCmdToCtrl, (kc == kVK_Command || kc == kVK_RightCommand), isSAIFrontmost() else {
            return Unmanaged.passUnretained(event)
        }
        event.setIntegerValueField(.keyboardEventKeycode, value: kVK_Control)
        var f = event.flags
        if f.contains(.maskCommand) { f.remove(.maskCommand); f.insert(.maskControl) }
        event.flags = f
        return Unmanaged.passUnretained(event)
    }

    // keyDown / keyUp: for allowlisted keys pressed with Cmd, swap the modifier
    // flag Cmd -> Ctrl (Shift/Option preserved). Non-allowlisted keys (incl.
    // Cmd+Tab / Cmd+Space / Cmd+Q) pass through untouched.
    guard remapCmdToCtrl, event.flags.contains(.maskCommand) else {
        return Unmanaged.passUnretained(event)
    }
    let kc = event.getIntegerValueField(.keyboardEventKeycode)
    guard remapKeys.contains(kc), isSAIFrontmost() else {
        return Unmanaged.passUnretained(event)
    }
    var flags = event.flags
    flags.remove(.maskCommand)
    flags.insert(.maskControl)
    event.flags = flags
    return Unmanaged.passUnretained(event)
}

if !AXIsProcessTrusted() {
    print("WARNING: not trusted for Accessibility — the tap will capture nothing.")
    print("Grant this terminal BOTH Accessibility and Input Monitoring in")
    print("System Settings → Privacy & Security, restart the terminal, and re-run.")
}

// virtual-desktop bounds now + on every display change (monitor plug/unplug)
refreshVirtualBounds()
let reconfigCB: CGDisplayReconfigurationCallBack = { _, _, _ in refreshVirtualBounds() }
CGDisplayRegisterReconfigurationCallback(reconfigCB, nil)

let mask: CGEventMask =
    (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)    |
    (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue) |
    (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)      |
    (CGEventMask(1) << CGEventType.mouseMoved.rawValue)       |
    (CGEventMask(1) << CGEventType.tabletPointer.rawValue)    |
    (CGEventMask(1) << CGEventType.tabletProximity.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,               // earliest point: least coalescing
    place: .headInsertEventTap,
    options: .listenOnly,              // passive: we never modify events
    eventsOfInterest: mask,
    callback: tapCallback,
    userInfo: nil
) else {
    if isAppMode {
        alertUser("SAI Pen Pressure needs permission to read the tablet.\n\nOpen System Settings → Privacy & Security, add \"SAI Pen Pressure\" to BOTH \"Accessibility\" and \"Input Monitoring\", then reopen this app.\n\n(SAI will keep running; pressure starts once permission is granted and you reopen.)")
    } else {
        print("ERROR: CGEvent.tapCreate failed — grant Accessibility + Input")
        print("Monitoring to this terminal, restart it, and re-run.")
    }
    exit(1)
}
gTap = tap
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// keepalive timer: while the pen is in proximity but idle, resend the last
// sample so SAI keeps the OS arrow cursor hidden (it flickered back in gaps).
let kaTimer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.04, 0.04, 0, 0) { _ in
    keepAlive()
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), kaTimer, .commonModes)

// keyboard remap tap — ACTIVE (can modify events), at the session level so it
// rewrites key events before apps receive them. Optional: if it can't be
// created, pressure still works; only the Cmd->Ctrl remap is unavailable.
if remapCmdToCtrl {
    let keyMask: CGEventMask =
        (CGEventMask(1) << CGEventType.keyDown.rawValue) |
        (CGEventMask(1) << CGEventType.keyUp.rawValue)   |
        (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
    if let keyTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,          // active: allowed to modify events
        eventsOfInterest: keyMask,
        callback: keyCallback,
        userInfo: nil
    ) {
        gKeyTap = keyTap
        let ksrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), ksrc, .commonModes)
        CGEvent.tapEnable(tap: keyTap, enable: true)
        print("Cmd→Ctrl remap active (only while SAI is frontmost).")
    } else {
        print("WARNING: keyboard remap tap failed (needs Accessibility) — Cmd→Ctrl off.")
    }
}

writeFile("0")                          // start pen-up
signal(SIGINT) { _ in
    try? "0".write(toFile: outPath, atomically: true, encoding: .ascii)
    print("\nstopped (pen released).")
    exit(0)
}

if isAppMode { launchSAIApp() }
print("wacom-pressure-helper (CGEventTap) running — writing to \(outPath)")
print("Draw with the pen; 'captured=N pressure=P' lines should appear. Ctrl+C to quit.")
CFRunLoopRun()

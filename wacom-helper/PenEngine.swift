// PenEngine.swift — the pen path: the event tap that reads the tablet, and the
// stream of samples it sends to our wintab32.dll inside SAI.
//
// Moved out of main.swift unchanged, apart from how udpAddr is filled in (see
// there). This is the part of the app the rest exists to protect, so it is kept
// free of everything else: no window, no setup, and no waiting for the disk
// (the sample file is written on a background queue, LatestFileWriter.swift).
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
// The pure rules (mapping, clamping, the keepalive, the pen-up latch) are in
// PressureCore.swift, where they are unit-tested. What is here is the OS glue.
//
// One thing stays in main.swift on purpose: the two lines that read the screen
// layout at launch and register for screen changes. They are statements, and
// only main.swift runs statements.

import AppKit
import CoreGraphics
import Foundation

// OUR OWN app is called "SAI Pen Pressure", which contains "sai" — so every
// window scan that looks for SAI by owner name was also matching our setup
// window. It was decided purely by area: Wine's window (1007x554) beat ours
// (726x760) by about 1%, so resizing our window was enough to make the app
// treat ITSELF as SAI — wrong wake target, wrong menu strip, wrong "is SAI
// still open". Always exclude our own process.
let g_myPID = ProcessInfo.processInfo.processIdentifier

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
// Built in one expression: outside main.swift a global cannot be filled in by
// statements that follow it.
var udpAddr: sockaddr_in = {
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = in_port_t(UInt16(47800).bigEndian)
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    return a
}()

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

// The sample file is written OFF the pen path (LatestFileWriter.swift says why
// and what it guarantees). The tap hands the newest sample over and moves on;
// it used to wait here for the disk, once per pen sample.
let penFile = LatestFileWriter(path: outPath)
func writeFile(_ s: String) {
    penFile.write(s)
}

// ---- times for the DLL's stroke-start trace (PressureCore.wireLine says why) --
// The stamp macOS put on the pen event being handled right now, in
// microseconds; nil outside the tap (keepalive, the pen-up latch timer), where
// there is no event, and nil for an event whose stamp cannot be used. nil is
// sent as "unknown", never as a made-up time.
var g_evUs: Int?
// How many pen samples have reached emit(). Compared with seq by the DLL: the
// difference is what our own rules dropped.
var g_emitCalls = 0
let g_timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

func nowUs() -> Int { Int(truncatingIfNeeded: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000) }

// What the stamps turned out to be, said in the log ONCE per kind (usable in
// nanoseconds, in ticks, in microseconds, unusable), with the raw numbers, so
// a trace full of "ev+?" comes with its own explanation. 0 ns, 1 ticks,
// 2 microseconds, 3 unusable. Never more than four lines a session: this runs
// in the tap.
var g_evSaid = [false, false, false, false]

func eventUs(_ event: CGEvent) -> Int? {
    let stamp = event.timestamp
    let nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let got = PressureCore.eventStampUs(stamp: stamp, nowNs: nowNs,
                                        numer: g_timebase.numer, denom: g_timebase.denom)
    let kind: Int
    switch got?.unit {
    case .nanoseconds?: kind = 0
    case .ticks?: kind = 1
    case .microseconds?: kind = 2
    case nil: kind = 3
    }
    if !g_evSaid[kind] {
        g_evSaid[kind] = true
        let what = ["usable, in nanoseconds", "usable, in mach ticks", "usable, in microseconds",
                    "UNUSABLE (not a recent time in ns, ticks or us); sent as unknown"][kind]
        wlog("pen event stamp \(what): raw=\(stamp) nowNs=\(nowNs) nowTicks=\(mach_absolute_time()) continuousTicks=\(mach_continuous_time()) type=\(event.type.rawValue) timebase \(g_timebase.numer)/\(g_timebase.denom)")
    }
    return got?.us
}

func send(_ p: Int, _ xf: Int, _ yf: Int) {
    seq += 1
    let wf = Int(vW * 8), hf = Int(vH * 8)
    let tx = nowUs()
    sendUDP(PressureCore.wireLine(seq: seq, p: p, xf: xf, yf: yf, wf: wf, hf: hf,
                                  evUs: g_evUs, txUs: tx, n: g_emitCalls))   // UDP: seq + sample + times
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
    g_emitCalls += 1
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
    // Behind the flag: this "state change" flips between active and "pen is
    // down" twice a second for as long as someone draws, so logging every
    // change fills the Developer log with keepalive lines and buries the
    // events worth reading. The state is still tracked, just not narrated.
    if st != g_lastKAState { g_lastKAState = st; if wakeLogOn { wlog("keepalive \(st)") } }
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
    // For the stroke-start trace: every send made while this event is handled
    // carries the event's own stamp. Cleared on the way out so a timer's send
    // (keepalive, pen-up latch) is never given a stale one.
    g_evUs = eventUs(event)
    defer { g_evUs = nil }
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

// PressureCore.swift — the PURE logic of the pressure helper, extracted so it
// can be unit-tested (tests/CoreTests.swift) without a tablet, permissions, or
// an event tap. main.swift keeps only the OS glue (CGEventTap, UDP, AppKit).
//
// Build: this file is compiled TOGETHER with main.swift:
//   swiftc -O -o wacom-pressure-helper main.swift PressureCore.swift
//
// Everything here is deterministic input -> output. If you change behaviour
// here, add/adjust a case in tests/CoreTests.swift.

import Foundation

enum PressureCore {

    /// Hard ceiling of the wire format — must match `WTC_MAX_PRESS` in
    /// wintab-src/wintab_core.h. The ACTIVE full scale is chosen at runtime
    /// (see `maxPressure`) and is normally whatever the tablet reports.
    ///
    /// History worth keeping: hard-coding 8191 for issue #21 made stroke width
    /// visibly wobble. Two reasons, both instructive — de-duplication compared
    /// pressure for exact equality, so 1024-level quantisation had been silently
    /// filtering sensor jitter; and the tablet in question only had 4096 levels,
    /// so the extra range was upsampled noise rather than detail. Hence: follow
    /// the hardware, and filter with `pressureDeadband` rather than by accident.
    static let maxPressureCeiling = 8191

    /// Levels offered in the setup window. 1024 is the long-standing default and
    /// stays first for a reason: it is the quietest.
    static let pressureChoices = [1023, 2047, 4095, 8191]

    /// Active full-scale pressure. Settable so the user can trade resolution
    /// against jitter; both halves of the bridge read the same stored value.
    static var maxPressure = 1023

    /// Which full scale to run at, in precedence order. Pure so the ordering is
    /// pinned by tests rather than by reading four call sites.
    ///
    /// `cached` is the point of this function (issue #27). Detection asks the
    /// hardware once, at helper startup — and a Bluetooth tablet that has idled
    /// out answers nothing at that instant, so `detected` is nil for a reason
    /// that has nothing to do with the tablet's real resolution. Falling
    /// straight through to 1023 silently cost 4x resolution on a 4096-level pen
    /// with no warning anywhere. A value the hardware gave us on a previous run
    /// is a far better guess than the generic default, so remembering the last
    /// successful answer turns a permanent degradation into, at worst, one
    /// coarse session on a brand-new install.
    ///
    /// An explicit user override still beats everything: they can see the
    /// result and we cannot.
    static func resolveMaxPressure(override: Int?, detected: Int?, cached: Int?) -> Int {
        return override ?? detected ?? cached ?? 1023
    }

    /// Bar position for a setup step whose real progress cannot be observed
    /// (issue #28). `wineboot` prints nothing parseable and takes about a
    /// minute, so there is no true percentage — but a bar frozen for a minute
    /// is read as a hang, which is the complaint this exists to answer.
    ///
    /// Approaches `to` asymptotically and **never reaches it**: only the next
    /// step moves the bar past `to`. So the bar is always moving while work is
    /// happening, yet never claims progress nobody observed. A step that
    /// overruns its estimate keeps creeping, ever more slowly, rather than
    /// sitting at 100% and lying about it.
    ///
    /// `tau = expected/2` puts it ~86% of the way at the expected duration —
    /// far enough to feel like real progress, with headroom left for overrun.
    /// The `1 - 1e-9` clamp is load-bearing, not paranoia: for a long enough
    /// elapsed time `exp(-elapsed/tau)` underflows to exactly 0, the approach
    /// term becomes exactly 1, and the bar lands on `to` — displaying a step as
    /// complete while it is still running. Caught by a test asserting the
    /// invariant, not by inspection.
    static func setupCreep(from: Double, to: Double, elapsed: Double, expected: Double) -> Double {
        let tau = max(0.5, expected / 2)
        let approach = min(1 - 1e-9, 1 - exp(-max(0, elapsed) / tau))
        return from + (to - from) * approach
    }

    static func clampPressure(_ raw: Int) -> Int { max(0, min(maxPressure, raw)) }

    /// PEN FEEL — a response curve applied to the normalised 0…1 pressure
    /// BEFORE it is scaled and sent. `out = in ^ gamma`.
    ///
    ///   gamma < 1  softer: a light touch already gives thick strokes
    ///   gamma = 1  linear, exactly what the tablet reports (default)
    ///   gamma > 1  firmer: you have to lean on it to get full width
    ///
    /// Applied on our side, so unlike the level count it needs no agreement with
    /// the DLL and takes effect without restarting SAI. Note this stacks with
    /// the Wacom driver's own curve and with SAI's per-brush Min Size — which is
    /// why the default is 1.0: no surprises unless asked for.
    static var pressureGamma = 1.0

    /// Endpoints are fixed points of the curve (0→0, 1→1), so only the shape
    /// between them changes — full press always stays full press.
    static func curved(_ normalised: Double) -> Double {
        guard pressureGamma != 1.0, normalised > 0, normalised < 1 else { return normalised }
        return pow(normalised, pressureGamma)
    }

    /// Minimum pressure change worth sending, in wire units.
    ///
    /// This is the piece that was missing when 8192 levels first went in: with
    /// exact-equality de-duplication, quantising to 1024 was silently filtering
    /// sensor jitter, and removing it made stroke width visibly wobble. So the
    /// deadband scales with the chosen resolution — one 1024th of full scale,
    /// i.e. the same noise rejection as the old default, at any setting. Real
    /// pressure changes still arrive at the finer resolution; only sub-threshold
    /// jitter is dropped.
    static var pressureDeadband: Int { max(1, maxPressure / 1024) }

    /// Map a global mac cursor location (top-left origin, y-down, points) to
    /// the wire format: position RELATIVE to the virtual-desktop origin,
    /// flipped to bottom-left y-up (the WinTab direction), in 8x fixed point
    /// (preserves sub-pixel precision through the integer protocol).
    static func mapToVirtual(locX: Double, locY: Double,
                             vX: Double, vY: Double, vH: Double) -> (xf: Int, yf: Int) {
        (Int((locX - vX) * 8), Int(((vY + vH) - locY) * 8))
    }

    /// Drop consecutive identical samples (also de-dups any doubled tap events).
    static func isDuplicate(p: Int, xf: Int, yf: Int,
                            lastP: Int, lastX: Int, lastY: Int) -> Bool {
        p == lastP && xf == lastX && yf == lastY
    }

    /// Should this sample be skipped? Exact duplicates always; plus, when the
    /// pen hasn't MOVED, pressure wobble smaller than the deadband.
    ///
    /// Tip transitions are never swallowed: a sample where either side is 0 is
    /// a pen-down or pen-up, and dropping one would lose a stroke boundary.
    /// Movement always passes too — position is what draws the line; only
    /// stationary pressure noise is filtered.
    static func shouldSkip(p: Int, xf: Int, yf: Int,
                           lastP: Int, lastX: Int, lastY: Int,
                           deadband: Int) -> Bool {
        if isDuplicate(p: p, xf: xf, yf: yf, lastP: lastP, lastX: lastX, lastY: lastY) { return true }
        guard deadband > 1 else { return false }
        guard xf == lastX, yf == lastY else { return false }   // moved: always send
        guard p > 0, lastP > 0 else { return false }           // tip transition: always send
        return abs(p - lastP) < deadband
    }

    /// KEEPALIVE rule: while the pen hovers in range with no movement, resend
    /// the last sample at a low rate so SAI keeps thinking a pen is present
    /// (the OS arrow cursor flickered back during quiet gaps). ONLY when the
    /// last sample was pen-up/hover (pressure 0): re-sending an actual press
    /// made SAI register spurious extra clicks.
    /// - Parameters:
    ///   - penInRange: the pen is PHYSICALLY in range — a fact about the pen,
    ///     changed only by real proximity/tablet events.
    ///   - secondsSinceMouseUse: how long since a plain mouse/trackpad event.
    ///
    /// The pen-in-range flag used to be cleared by any mouse event, conflating
    /// "the pen is here" with "the pen is what you're using". That mattered
    /// because clicking Launch with the trackpad cleared it, and a pen already
    /// resting on the tablet fires no *new* proximity event — proximity only
    /// reports transitions. So nothing told SAI a pen existed and the macOS
    /// arrow sat over SAI's brush cursor (issue #20).
    ///
    /// Splitting them keeps both behaviours: the keepalive follows the pen, and
    /// a mouse-idle grace period still stops hover packets while the mouse is
    /// actually in use — which is what lets SAI paint with the mouse at all.
    static func keepAliveShouldResend(penInRange: Bool, lastPressure: Int,
                                      secondsSinceLastSend: Double,
                                      secondsSinceMouseUse: Double,
                                      mouseIdleGrace: Double = 1.0) -> Bool {
        penInRange
            && lastPressure == 0
            && secondsSinceLastSend > 0.05
            && secondsSinceMouseUse > mouseIdleGrace
    }

    /// PEN-UP LATCH (pen tap = double click bug): a light tap, or lifting away
    /// but staying near the surface, can make the tablet's pressure dip through
    /// zero and back — one physical touch reported as TWO (field log: DOWN/UP
    /// then DOWN again at the same spot 72 ms later). So a pen-up is not sent
    /// immediately: it is held for `latch` seconds, and if pressure returns
    /// within that window CLOSE to where the pen went up, the dip is absorbed
    /// and the touch continues as one. Returns true when the returning press is
    /// that same touch (bounce), false when it is a genuine new touch.
    /// Coordinates are in the 8x fixed-point wire format; `radiusF` 48 = 6 pt (field-log bounces re-touch within ~2 pt).
    /// Human double-taps run slower than `latch`, so they still pass.
    static func upLatchAbsorbs(secondsSincePenUp: Double, xf: Int, yf: Int,
                               upX: Int, upY: Int,
                               latch: Double = 0.15, radiusF: Int = 48) -> Bool {
        secondsSincePenUp < latch && abs(xf - upX) <= radiusF && abs(yf - upY) <= radiusF
    }

    /// Union of all display bounds = the full virtual desktop, in the global
    /// top-left-origin space CGEvent.location uses. The pen position is
    /// reported within THIS combined space so a 2nd monitor maps correctly
    /// instead of producing a doubled cursor.
    static func virtualUnion(of rects: [(x: Double, y: Double, w: Double, h: Double)])
        -> (x: Double, y: Double, w: Double, h: Double)? {
        guard !rects.isEmpty else { return nil }
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for r in rects {
            minX = min(minX, r.x); minY = min(minY, r.y)
            maxX = max(maxX, r.x + r.w); maxY = max(maxY, r.y + r.h)
        }
        return (minX, minY, maxX - minX, maxY - minY)
    }
}

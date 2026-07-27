// CoreTests.swift — unit tests for PressureCore (the helper's pure logic).
// No XCTest/SPM on purpose: zero dependencies, runs anywhere swiftc exists.
//
// Run:  bash tests/run-tests.sh      (builds + runs this and the C core tests)

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String,
            file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

@main
struct CoreTests {
    static func main() {

        print("PressureCore tests:")

        // --- clampPressure -----------------------------------------------------------
        expect(PressureCore.clampPressure(-5) == 0,      "clamp: negative -> 0")
        expect(PressureCore.clampPressure(0) == 0,       "clamp: zero stays 0")
        expect(PressureCore.clampPressure(512) == 512,   "clamp: mid passes through")
        expect(PressureCore.clampPressure(1023) == 1023, "clamp: max stays 1023")

        // pen feel: endpoints pinned, middle bends the expected way
        PressureCore.pressureGamma = 1.0
        expect(PressureCore.curved(0.5) == 0.5, "curve: linear leaves 0.5 alone")
        PressureCore.pressureGamma = 0.5
        expect(PressureCore.curved(0.25) > 0.25, "curve: soft raises a light touch")
        expect(PressureCore.curved(0.0) == 0.0 && PressureCore.curved(1.0) == 1.0, "curve: soft pins 0 and 1")
        PressureCore.pressureGamma = 2.0
        expect(PressureCore.curved(0.5) < 0.5, "curve: firm needs more press")
        expect(PressureCore.curved(1.0) == 1.0, "curve: firm still reaches full")
        PressureCore.pressureGamma = 1.0
        expect(PressureCore.clampPressure(4096) == 1023, "clamp: overshoot -> 1023")

        // --- mapToVirtual ------------------------------------------------------------
        // Single 1440x900 screen at origin: top-left corner -> (0, 900*8), y flipped.
        var m = PressureCore.mapToVirtual(locX: 0, locY: 0, vX: 0, vY: 0, vH: 900)
        expect(m.xf == 0 && m.yf == 900 * 8, "map: top-left flips to y-up top")
        // bottom-left corner -> y = 0
        m = PressureCore.mapToVirtual(locX: 0, locY: 900, vX: 0, vY: 0, vH: 900)
        expect(m.xf == 0 && m.yf == 0, "map: bottom-left -> origin")
        // 8x fixed point preserves sub-pixel precision
        m = PressureCore.mapToVirtual(locX: 10.5, locY: 0, vX: 0, vY: 0, vH: 900)
        expect(m.xf == 84, "map: sub-pixel (10.5pt -> 84 fixed)")
        // second monitor left of the primary: virtual origin is negative
        m = PressureCore.mapToVirtual(locX: -1000, locY: 100, vX: -1920, vY: 0, vH: 1080)
        expect(m.xf == (-1000 - -1920) * 8, "map: negative virtual origin (2nd monitor left)")
        expect(m.yf == (1080 - 100) * 8, "map: y-flip within full virtual desktop")

        // --- isDuplicate ------------------------------------------------------------
        expect(PressureCore.isDuplicate(p: 5, xf: 1, yf: 2, lastP: 5, lastX: 1, lastY: 2),
               "dedup: identical sample dropped")
        expect(!PressureCore.isDuplicate(p: 6, xf: 1, yf: 2, lastP: 5, lastX: 1, lastY: 2),
               "dedup: pressure change passes")
        expect(!PressureCore.isDuplicate(p: 5, xf: 3, yf: 2, lastP: 5, lastX: 1, lastY: 2),
               "dedup: position change passes")

        // --- keepAliveShouldResend ---------------------------------------------------
        // The rule that fixed the double-click bug: resend ONLY hover (pressure 0).
        expect(PressureCore.keepAliveShouldResend(penInRange: true, lastPressure: 0,
                                                 secondsSinceLastSend: 0.06, secondsSinceMouseUse: 5),
               "keepalive: hover + idle resends")
        expect(!PressureCore.keepAliveShouldResend(penInRange: true, lastPressure: 200,
                                                  secondsSinceLastSend: 0.06, secondsSinceMouseUse: 5),
               "keepalive: NEVER resends a press (double-click bug)")
        expect(!PressureCore.keepAliveShouldResend(penInRange: false, lastPressure: 0,
                                                  secondsSinceLastSend: 0.06, secondsSinceMouseUse: 5),
               "keepalive: pen out of range -> silent (mouse can paint)")
        expect(!PressureCore.keepAliveShouldResend(penInRange: true, lastPressure: 0,
                                                  secondsSinceLastSend: 0.02, secondsSinceMouseUse: 5),
               "keepalive: not yet idle (<50ms) -> no resend")
        // issue #20: the pen stays in range while the mouse is used, so the
        // keepalive must pause for the mouse and resume by itself afterwards.
        expect(!PressureCore.keepAliveShouldResend(penInRange: true, lastPressure: 0,
                                                  secondsSinceLastSend: 0.06, secondsSinceMouseUse: 0.2),
               "keepalive: mouse just used -> stay quiet so SAI can paint with it")
        expect(PressureCore.keepAliveShouldResend(penInRange: true, lastPressure: 0,
                                                 secondsSinceLastSend: 0.06, secondsSinceMouseUse: 2.0),
               "keepalive: mouse gone idle -> pen reasserts itself, arrow hides again")

        // --- upLatchAbsorbs ----------------------------------------------------------
        // Pen-tap bounce fix: a pressure dip through zero at ~the same spot within
        // the latch window is ONE physical touch, not two (single tap on a brush
        // slot opened SAI's double-click Property dialog).
        expect(PressureCore.upLatchAbsorbs(secondsSincePenUp: 0.072, xf: 2368, yf: 4892, upX: 2360, upY: 4896),
               "latch: 72ms same-spot retouch is a bounce (field log case)")
        expect(!PressureCore.upLatchAbsorbs(secondsSincePenUp: 0.2, xf: 2368, yf: 4892, upX: 2360, upY: 4896),
               "latch: slow retouch (200ms) is a real double-tap")
        expect(!PressureCore.upLatchAbsorbs(secondsSincePenUp: 0.05, xf: 2368, yf: 4892, upX: 3000, upY: 4896),
               "latch: fast retouch far away is a real new touch")
        expect(PressureCore.upLatchAbsorbs(secondsSincePenUp: 0.119, xf: 100, yf: 100, upX: 100 + 48, upY: 100),
               "latch: edge of window+radius still absorbs")

        // (Cmd->Ctrl remap is now handled by Wine's LeftCommandIsCtrl, not the
        //  helper, so there's no shouldRemapKey logic to test here anymore.)

        // --- virtualUnion ------------------------------------------------------------
        expect(PressureCore.virtualUnion(of: []) == nil, "union: no displays -> nil (caller falls back)")
        var u = PressureCore.virtualUnion(of: [(x: 0, y: 0, w: 1440, h: 900)])!
        expect(u == (0, 0, 1440, 900), "union: single screen is itself")
        u = PressureCore.virtualUnion(of: [(0, 0, 1440, 900), (1440, 0, 1920, 1080)])!
        expect(u == (0, 0, 3360, 1080), "union: side-by-side extends right")
        u = PressureCore.virtualUnion(of: [(0, 0, 1440, 900), (-1920, -200, 1920, 1080)])!
        expect(u == (-1920, -200, 3360, 1100), "union: monitor up-left gives negative origin")

        // -----------------------------------------------------------------------------
        // ---- resolveMaxPressure: precedence (issue #27) -------------------------
    // The cached term exists because a Bluetooth tablet asleep at startup
    // reports nothing, and falling through to 1023 cost 4x resolution silently.
    expect(PressureCore.resolveMaxPressure(override: 2047, detected: 4095, cached: 8191) == 2047,
           "pmax: explicit override beats everything")
    expect(PressureCore.resolveMaxPressure(override: 2047, detected: nil, cached: nil) == 2047,
           "pmax: override alone is honoured")
    expect(PressureCore.resolveMaxPressure(override: nil, detected: 4095, cached: 1023) == 4095,
           "pmax: live detection beats a stale cache")
    expect(PressureCore.resolveMaxPressure(override: nil, detected: nil, cached: 4095) == 4095,
           "pmax: sleeping BT tablet falls back to last known good, NOT 1023 (#27)")
    expect(PressureCore.resolveMaxPressure(override: nil, detected: nil, cached: nil) == 1023,
           "pmax: nothing known -> 1023 default")
    expect(PressureCore.resolveMaxPressure(override: nil, detected: 4095, cached: nil) == 4095,
           "pmax: first ever run with the tablet awake")
    // The regression this replaces: detection failing used to mean 1023 even
    // though the hardware had already told us 4095 on an earlier launch.
    expect(PressureCore.resolveMaxPressure(override: nil, detected: nil, cached: 4095) != 1023,
           "pmax: a known 4096-level tablet never silently drops to 1024 levels")

    if failures > 0 { print("FAILED: \(failures) test(s)"); exit(1) }
        print("All PressureCore tests passed.")
    }
}

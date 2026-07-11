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

    /// Tablet pressure is carried as 0...1023 end-to-end (WinTab convention).
    static func clampPressure(_ raw: Int) -> Int { max(0, min(1023, raw)) }

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

    /// KEEPALIVE rule: while the pen hovers in range with no movement, resend
    /// the last sample at a low rate so SAI keeps thinking a pen is present
    /// (the OS arrow cursor flickered back during quiet gaps). ONLY when the
    /// last sample was pen-up/hover (pressure 0): re-sending an actual press
    /// made SAI register spurious extra clicks.
    static func keepAliveShouldResend(inProximity: Bool, lastPressure: Int,
                                      secondsSinceLastSend: Double) -> Bool {
        inProximity && lastPressure == 0 && secondsSinceLastSend > 0.05
    }

    /// Cmd->Ctrl remap decision for a keyDown/keyUp: only allowlisted keys,
    /// only while SAI is frontmost, and only when Cmd is actually held.
    /// Everything else (incl. Cmd+Tab / Cmd+Space / Cmd+Q) passes through.
    static func shouldRemapKey(keycode: Int64, hasCommand: Bool,
                               saiFrontmost: Bool, allowlist: Set<Int64>) -> Bool {
        hasCommand && saiFrontmost && allowlist.contains(keycode)
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

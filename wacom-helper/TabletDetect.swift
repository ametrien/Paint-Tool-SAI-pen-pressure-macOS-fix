// TabletDetect.swift — asking the connected tablet what it is and how many
// pressure levels it has.
//
// Moved out of main.swift unchanged. It is on its own because nothing else
// talks to IOKit's HID manager, and because three unrelated places ask the
// same question: the Pen tab, the session header in the log, and the problem
// report.

import Foundation
import IOKit.hid

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
    /// levels - 1, or nil when the tablet is connected but will not say — which
    /// is every Wacom over Bluetooth. See PressureCore.classifyTablet.
    let fullScale: Int?
    /// "USB", "Bluetooth", ... Worth reporting: it decides whether the range is
    /// readable at all, and Bluetooth's lower sample rate is the known cause of
    /// boxy fast curves.
    let transport: String
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
        var spans: [Int] = []
        var vendorDigitizer = false
        for e in els {
            let page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e)
            // The VENDOR digitizer page is what a Wacom falls back to over
            // Bluetooth, where it publishes no readable pressure element at
            // all. The standard page 0x0D deliberately does NOT count here: a
            // MacBook trackpad advertises that one.
            if page == 0xFF0D { vendorDigitizer = true }
            // 0x30 = Tip Pressure, on the standard or the vendor digitizer page.
            guard usage == 0x30, page == 0x0D || page == 0xFF0D else { continue }
            spans.append(Int(IOHIDElementGetLogicalMax(e)) - Int(IOHIDElementGetLogicalMin(e)))
        }
        let kind = PressureCore.classifyTablet(pressureSpans: spans, hasVendorDigitizer: vendorDigitizer)
        let best: Int?
        switch kind {
        case .notATablet:            continue
        case .rangeUnknown:          best = nil
        case .tablet(let fullScale): best = fullScale
        }
        let maker = (IOHIDDeviceGetProperty(d, kIOHIDManufacturerKey as CFString) as? String) ?? ""
        let prod  = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "tablet"
        // "Wacom Co.,Ltd." + "Intuos BT S" reads badly; keep it short.
        let short = maker.split(separator: " ").first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,")) ?? ""
        let name = (short.isEmpty || prod.lowercased().contains(short.lowercased())) ? prod : "\(short) \(prod)"
        let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? "?"
        found.append(TabletInfo(name: name, fullScale: best, transport: transport))
    }
    // A tablet that states its range outranks one that doesn't, so Auto follows
    // something it can actually read rather than a silent Bluetooth device.
    return found.sorted { ($0.fullScale ?? -1) > ($1.fullScale ?? -1) }
}

/// The tablet we follow in Auto mode: the highest-resolution one connected.
func detectTablet() -> TabletInfo? { detectTablets().first }

func detectTabletFullScale() -> Int? { detectTablet()?.fullScale ?? nil }

/// The connected tablets FOR DISPLAY: the newest scan there is, never waited
/// for (after the first). The Pen tab shows this every second, and a scan
/// takes about 20 ms, which is too long to spend on the thread the pen is
/// read on (RefreshCache.swift). A tablet plugged in or switched off shows up
/// two to three seconds later.
///
/// Only for showing. Anything that DECIDES from the tablet (the pressure
/// levels sent to SAI at launch, the warning when you pick more levels than
/// the tablet has) still calls detectTablets() and gets the answer of that
/// moment.
let g_tabletsForDisplay = BackgroundLatest<[TabletInfo]>(maxAge: 2) { detectTablets() }
func tabletsForDisplay() -> [TabletInfo] { g_tabletsForDisplay.get() }

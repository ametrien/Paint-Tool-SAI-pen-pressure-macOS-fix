// handoff-test: does Wine 11.16's way of handing a window picture to macOS
// cost CPU because of the colour profile (sRGB vs the display's P3) or
// because of the shape mask? See RETINA-LAG-FINDINGS.md.
//
// Copies what winemac.drv does in 11.16 (surface.c macdrv_surface_flush,
// cocoa_window.m updateLayer): a 32-bit BGRX picture over a data provider,
// tagged with a colour space, optionally wrapped with CGImageCreateWithMask,
// cut with CGImageCreateWithImageInRect and set as layer.contents on every
// update. A small patch changes each frame, like a brush stroke.
//
// Runs each variant for a few seconds at 60 updates/s in a Retina window and
// prints the CPU time the process used. Build for x86_64 to run under
// Rosetta like Wine does. Opens one window; quits by itself.

import AppKit

let secondsPerVariant = 8.0
let pointSize = NSSize(width: 1352, height: 830)

struct Variant { let name: String; let space: CGColorSpace; let mask: Bool }
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let variants = [
    Variant(name: "sRGB + mask (Wine 11.16)", space: srgb, mask: true),
    Variant(name: "sRGB, no mask", space: srgb, mask: false),
    Variant(name: "P3 + mask", space: p3, mask: true),
    Variant(name: "P3, no mask", space: p3, mask: false),
]

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
         + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

final class Surface {
    let w: Int, h: Int, stride: Int
    let bits: UnsafeMutablePointer<UInt8>
    let provider: CGDataProvider
    let maskImage: CGImage
    var frame = 0

    init(w: Int, h: Int) {
        self.w = w; self.h = h; stride = w * 4
        bits = .allocate(capacity: stride * h)
        bits.initialize(repeating: 0xff, count: stride * h)
        provider = CGDataProvider(dataInfo: nil, data: bits, size: stride * h, releaseData: { _, _, _ in })!
        // Wine's shape image: an 8-bit mask, here fully opaque.
        let m = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        m.initialize(repeating: 0, count: w * h)   // 0 = paint in an image mask
        let mp = CGDataProvider(dataInfo: nil, data: m, size: w * h, releaseData: { _, _, _ in })!
        maskImage = CGImage(maskWidth: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                            bytesPerRow: w, provider: mp, decode: nil, shouldInterpolate: false)!
    }

    /// Change a small square, like one brush dab.
    func dab() {
        frame += 1
        let x = (frame * 37) % (w - 64), y = (frame * 23) % (h - 64)
        for r in 0..<64 {
            let row = bits + (y + r) * stride + x * 4
            for c in 0..<64 { row[c * 4] = UInt8(frame & 0xff); row[c * 4 + 1] = 0x40 }
        }
    }

    func image(_ v: Variant) -> CGImage? {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let color = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: stride, space: v.space, bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        let masked = v.mask ? color.masking(maskImage) : color
        return masked?.cropping(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
}

final class Driver: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var layer: CALayer!
    var surface: Surface!
    var timer: Timer?
    var index = 0
    var startCPU = 0.0, startTime = 0.0, frames = 0
    var results: [String] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: pointSize),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "handoff-test (closes by itself)"
        let view = NSView(frame: NSRect(origin: .zero, size: pointSize))
        view.wantsLayer = true
        layer = view.layer!
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        let scale = window.backingScaleFactor
        layer.contentsScale = scale
        surface = Surface(w: Int(pointSize.width * scale), h: Int(pointSize.height * scale))
        print("window \(Int(pointSize.width))x\(Int(pointSize.height)) pt, scale \(scale), "
              + "picture \(surface.w)x\(surface.h) px, display colour space: "
              + "\(window.screen?.colorSpace?.localizedName ?? "?")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.startVariant() }
    }

    func startVariant() {
        guard index < variants.count else { finish(); return }
        let v = variants[index]
        // Warm up so the first frames' setup is not counted.
        for _ in 0..<10 { surface.dab(); layer.contents = surface.image(v) }
        CATransaction.flush()
        startCPU = cpuSeconds(); startTime = CACurrentMediaTime(); frames = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.surface.dab()
            self.layer.contents = self.surface.image(v)
            self.frames += 1
            if CACurrentMediaTime() - self.startTime >= secondsPerVariant { self.endVariant(v) }
        }
    }

    func endVariant(_ v: Variant) {
        timer?.invalidate(); timer = nil
        CATransaction.flush()
        let cpu = cpuSeconds() - startCPU
        let wall = CACurrentMediaTime() - startTime
        let line = String(format: "%-26@ CPU %5.1f%% of a core   (%.2fs CPU in %.1fs, %d updates)",
                          v.name as NSString, cpu / wall * 100, cpu, wall, frames)
        print(line); fflush(stdout)
        results.append(line)
        index += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startVariant() }
    }

    func finish() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let driver = Driver()
app.delegate = driver
app.run()

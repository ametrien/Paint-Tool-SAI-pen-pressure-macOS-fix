// The app icon: "Pen" by gravisio from Flaticon on a soft light tile.
// Drawing icons created by gravisio - Flaticon: https://www.flaticon.com/free-icons/drawing
//
// Flaticon's free licence asks for that attribution (it is in NOTICE, which
// ships inside the app, and in the README) and does not let the picture be
// passed on by itself, so the picture is not in the repository. The finished
// icon, icon/AppIcon.icns, is: make-app.sh copies it, so building the app does
// not need this script. To draw the icon again:
//
//   curl -o icon/flaticon-11502485.png https://cdn-icons-png.flaticon.com/512/11502/11502485.png
//   swiftc -O -o /tmp/make-icon tools/make-icon.swift && /tmp/make-icon icon/AppIcon.icns [picture.png]
//
// The same pen and tile as SAI Pen for Android (its tools/make-icon.swift).
// Every size in the .icns is drawn from the picture itself, not scaled down
// from the largest one. The picture is 512 px, so only the 1024 px size
// (512 pt on a Retina screen) is drawn a little larger than the picture.
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon/AppIcon.icns"
let penPath = args.count > 2 ? args[2] : "icon/flaticon-11502485.png"
guard let pen = NSImage(contentsOfFile: penPath),
      let tiff = pen.tiffRepresentation, let penRep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write("no picture at \(penPath): download it first (see the top of this file)\n".data(using: .utf8)!)
    exit(1)
}
// the drawing's own box inside the PNG (pixels with any ink), so it is
// centred and sized by what is drawn, not by the PNG's empty margins
let art: NSRect = {
    var x0 = penRep.pixelsWide, y0 = penRep.pixelsHigh, x1 = -1, y1 = -1
    for y in 0..<penRep.pixelsHigh { for x in 0..<penRep.pixelsWide
        where (penRep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
    } }
    let k = pen.size.width / CGFloat(penRep.pixelsWide)
    // bitmap rows run top-down, NSImage coordinates bottom-up
    return NSRect(x: CGFloat(x0) * k, y: pen.size.height - CGFloat(y1 + 1) * k,
                  width: CGFloat(x1 - x0 + 1) * k, height: CGFloat(y1 - y0 + 1) * k)
}()

func render(px: Int, to path: String) {
    let side = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx

    // the tile the emoji icon had: 8 % margin, corners 18 % of the side, #F7F7F7
    let inset = side * 0.08
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: side * 0.18, yRadius: side * 0.18).fill()

    // the pen's longer side is 56 % of the icon, as on Android
    let scale = side * 0.56 / max(art.width, art.height)
    let w = art.width * scale, h = art.height * scale
    pen.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
             from: art, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.retagging(with: .sRGB)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("make-icon-\(ProcessInfo.processInfo.processIdentifier)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

for pt in [16, 32, 128, 256, 512] {
    render(px: pt, to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png").path)
    render(px: pt * 2, to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png").path)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outPath]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("icon written to \(outPath)")

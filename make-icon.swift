// Renders a pen emoji to a 1024x1024 PNG for the app icon.
// Usage: swiftc -O -o make-icon make-icon.swift && ./make-icon out.png
// (make-app.sh then downsizes it into an .iconset and runs iconutil.)
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon1024.png"
let emoji = ProcessInfo.processInfo.environment["ICON_EMOJI"] ?? "🖊️"
let side: CGFloat = 1024

let img = NSImage(size: NSSize(width: side, height: side))
img.lockFocus()

// Soft rounded-rectangle background so it reads as a real macOS app icon
// (transparent-background icons look unfinished in the Dock/Finder).
let inset: CGFloat = side * 0.08
let rect = NSRect(x: inset, y: inset, width: side - inset*2, height: side - inset*2)
let bg = NSBezierPath(roundedRect: rect, xRadius: side*0.18, yRadius: side*0.18)
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
bg.fill()

// Center the emoji glyph inside the tile.
let font = NSFont.systemFont(ofSize: side * 0.62)
let str = NSAttributedString(string: emoji, attributes: [.font: font])
let s = str.size()
str.draw(at: NSPoint(x: (side - s.width)/2, y: (side - s.height)/2))

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}
do { try png.write(to: URL(fileURLWithPath: outPath)) }
catch { FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!); exit(1) }

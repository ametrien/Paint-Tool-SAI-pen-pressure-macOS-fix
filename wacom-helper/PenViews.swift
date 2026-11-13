// PenViews.swift — the three small views the app draws itself: the pressure
// bar, the pen-feel curve plot, and the draw-here pad.
//
// Moved out of main.swift unchanged. They hold no app state and know nothing
// about setup or SAI, which is what makes them safe to read on their own.

import AppKit

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

/// Draw-here area for the pen test. The pressure bar proves a signal arrives;
/// this proves it FEELS right — taper at the ends of a stroke is the thing
/// people actually care about, and a number cannot show it.
///
/// Pressure comes from the event when macOS provides it, falling back to the
/// value our own tablet tap last saw, so it still works for input paths that
/// report no NSEvent pressure.
final class PenScratchView: NSView {
    private typealias Point = (p: CGPoint, w: CGFloat)
    private struct Stroke { var pts: [Point]; var finished: Date? }

    private var strokes: [Stroke] = []
    private var current: [Point] = []
    private var fade: Timer?

    /// How long a finished stroke stays solid, then how long it takes to vanish.
    /// Long enough to judge the taper, short enough that the pad is clean again
    /// by the time you come back to it — so there is nothing to press to reset.
    private let holdSeconds: TimeInterval = 2.0
    private let fadeSeconds: TimeInterval = 2.0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func clear() { strokes.removeAll(); current.removeAll(); stopFade(); needsDisplay = true }

    private func alpha(_ s: Stroke) -> CGFloat {
        guard let f = s.finished else { return 1 }              // still drawing
        let age = Date().timeIntervalSince(f) - holdSeconds
        if age <= 0 { return 1 }
        return max(0, 1 - CGFloat(age / fadeSeconds))
    }

    private func startFade() {
        guard fade == nil else { return }
        // 20fps is plenty for a fade and costs nothing; it stops itself as soon
        // as the pad is empty, so an idle window does no work at all.
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.strokes.removeAll { self.alpha($0) <= 0 }
            self.needsDisplay = true
            if self.strokes.isEmpty && self.current.isEmpty { self.stopFade() }
        }
        RunLoop.main.add(t, forMode: .common)
        fade = t
    }
    private func stopFade() { fade?.invalidate(); fade = nil }

    /// Runs the same pipeline the helper uses before sending a value to SAI, so
    /// the pad shows what the settings above it actually do rather than a
    /// prettier approximation of it.
    private func width(for e: NSEvent) -> CGFloat {
        // 1. raw 0…1. NSEvent carries pressure for tablet input; fall back to
        //    whatever our own tap last saw for paths that report none.
        var p = Double(e.pressure)
        if p <= 0 { p = Double(max(0, lastKeyP)) / Double(max(1, PressureCore.maxPressure)) }
        p = min(1, max(0, p))

        // 2. quantise to the configured level count, so picking 1024 against
        //    8192 is visible as steppier width rather than being invisible.
        let levels = Double(max(1, PressureCore.maxPressure))
        p = (p * levels).rounded() / levels

        // 3. pen feel and the feel curve are the same knob — both write
        //    PressureCore.pressureGamma — so one call covers both.
        p = PressureCore.curved(p)

        return 1 + CGFloat(p) * 22     // tapered without becoming a blob
    }

    override func mouseDown(with e: NSEvent) {
        current = [(convert(e.locationInWindow, from: nil), width(for: e))]
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        current.append((convert(e.locationInWindow, from: nil), width(for: e)))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        if current.count > 1 { strokes.append(Stroke(pts: current, finished: Date())) }
        current.removeAll()
        startFade()
        needsDisplay = true
    }

    override func draw(_ r: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill(); r.fill()
        NSColor.separatorColor.setStroke()
        frame.stroke()
        // Ink must stay inside the box. A drag continues to deliver points once
        // the pointer leaves the view, which is correct for tracking but must
        // not paint over the rest of the window.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        frame.setClip()

        if strokes.isEmpty && current.isEmpty {
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor]
            let t = "Draw here with your pen. Strokes taper with pressure, then fade"
            let sz = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                               y: (bounds.height - sz.height) / 2), withAttributes: a)
            return
        }

        var all = strokes
        if current.count > 1 { all.append(Stroke(pts: current, finished: nil)) }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for stroke in all {
            // A stroke is drawn as many round-capped segments, because its width
            // varies along its length and one path carries only one line width.
            // Fading them individually made every overlap blend twice, so the
            // line dissolved into a string of beads. A transparency layer
            // composites the whole stroke once, at one alpha, so it fades as a
            // single line.
            ctx.saveGState()
            ctx.setAlpha(alpha(stroke))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.labelColor.setStroke()
            for i in 1..<stroke.pts.count {
                let seg = NSBezierPath()
                seg.move(to: stroke.pts[i - 1].p)
                seg.line(to: stroke.pts[i].p)
                seg.lineWidth = (stroke.pts[i - 1].w + stroke.pts[i].w) / 2
                seg.lineCapStyle = .round
                seg.stroke()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }
}

/// Live plot of the pen-feel curve: input pressure across, output up. The
/// diagonal is linear (gamma 1); the dot is where the pen is right now, so you
/// can press and watch the mapping instead of interpreting a number.
final class GammaCurveView: NSView {
    var feel: PenFeel = .normal { didSet { if feel != oldValue { needsDisplay = true } } }
    var live: Double = 0 { didSet { if live != oldValue { needsDisplay = true } } }   // 0...1 input

    /// The plot goes through PressureCore.feel, the same function the pen goes
    /// through, so the picture cannot drift from the behaviour.
    private func map(_ x: Double) -> Double {
        PressureCore.feel(x, gamma: feel.gamma, floor: feel.floor, fullAt: feel.fullAt)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

        // linear reference
        NSColor.tertiaryLabelColor.setStroke()
        let diag = NSBezierPath()
        diag.move(to: NSPoint(x: r.minX, y: r.minY))
        diag.line(to: NSPoint(x: r.maxX, y: r.maxY))
        diag.lineWidth = 1
        diag.setLineDash([3, 3], count: 2, phase: 0)
        diag.stroke()

        // the actual curve (120 points: the floor makes a corner that 60
        // rounded off visibly)
        let curve = NSBezierPath()
        curve.lineWidth = 2
        for i in 0...120 {
            let x = Double(i) / 120.0
            let p = NSPoint(x: r.minX + CGFloat(x) * r.width, y: r.minY + CGFloat(map(x)) * r.height)
            if i == 0 { curve.move(to: p) } else { curve.line(to: p) }
        }
        NSColor.controlAccentColor.setStroke()
        curve.stroke()

        // where the pen is right now
        if live > 0.001 {
            let p = NSPoint(x: r.minX + CGFloat(live) * r.width, y: r.minY + CGFloat(map(live)) * r.height)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
    }
}

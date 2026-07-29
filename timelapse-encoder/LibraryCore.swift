// LibraryCore.swift — the PURE logic of the timelapse library: recognising that
// tonight's session continues a drawing started weeks ago, and organising the
// pieces that result.
//
// No AVFoundation, no filesystem, no SAI. Everything here is deterministic
// input -> output so it can be unit-tested with synthesised pixels; the app and
// the encoder supply the moving parts. If you change behaviour here, add or
// adjust a case in tests/LibraryTests.swift.
//
// ---------------------------------------------------------------------------
// WHY IDENTITY IS HARD, AND WHY IT IS SOLVED WITH PIXELS
// ---------------------------------------------------------------------------
// Within one SAI session a canvas is identified by its struct address, which is
// exact (SAI allocates a canvas once and never moves it) and completely useless
// afterwards: quit SAI and the same drawing comes back at a different address.
// So a NEW signal is needed for "this is the drawing I was working on last
// Tuesday", and every obvious candidate breaks:
//
//   canvas title     — the artist renames it; and every unsaved document in SAI
//                      is called "NewCanvas1", so two brand-new drawings are
//                      indistinguishable by name on the day they matter most.
//   document path    — survives a rename of the title, but not Save As, not a
//                      move in Finder, and we do not even have the offset for it
//                      (see TIMELAPSE-PLAN.md; it is an upgrade, not a
//                      prerequisite — `path` here is optional throughout).
//   dimensions       — thousands of drawings are 1000x700.
//
// What survives every rename is what the drawing LOOKS like: reopen a piece of
// work and it looks exactly as you left it — that is why you reopened it. So
// identity is decided on a 16x16 fingerprint of the canvas, compared between the
// closing frame of an existing piece and the opening frame of this session.
//
// ---------------------------------------------------------------------------
// THE RULE THAT MAKES THIS SAFE
// ---------------------------------------------------------------------------
// A wrong "these are the same drawing" welds two unrelated works into one video.
// A wrong "these are different" leaves two entries in a list. Those are not
// equally bad, so the ladder is deliberately asymmetric: it merges only on
// strong evidence, ASKS on plausible evidence, and stays separate otherwise.
// Nothing here ever blocks recording — a session always produces its own valid
// video first, and grouping is metadata applied afterwards.

import Foundation

// MARK: - fingerprints

/// A 16x16 greyscale fingerprint of a canvas.
///
/// Small on purpose. It has to survive re-rendering, a different mip level
/// between sessions, and the odd stray pixel, while still telling two drawings
/// apart — and it gets stored in the index for every piece forever, so it must
/// stay tiny. 256 bytes does both.
struct CanvasSignature: Equatable, Codable {
    static let side = 16

    /// Row-major, `side * side` greyscale samples.
    let cells: [UInt8]
    /// The canvas dimensions this was taken from. Kept for display and for the
    /// resize case; NOT used for matching, because a canvas resized between
    /// sessions is still the same drawing.
    let width: Int
    let height: Int

    var isValid: Bool { cells.count == CanvasSignature.side * CanvasSignature.side }

    /// Box-average a BGRA frame down to the fingerprint grid.
    ///
    /// Averaging rather than sampling matters: a single stroke moves a sampled
    /// pixel not at all or completely, while it moves an average a little. The
    /// distances below assume the smooth version.
    static func fingerprint(bgra: Data, width: Int, height: Int, stride: Int) -> CanvasSignature? {
        guard width > 0, height > 0, stride >= width * 4,
              bgra.count >= stride * height else { return nil }
        var cells = [UInt8](repeating: 0, count: side * side)
        bgra.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for gy in 0..<side {
                // Integer edges, so every source pixel lands in exactly one cell
                // and no row is counted twice or skipped.
                let y0 = height * gy / side, y1 = max(y0 + 1, height * (gy + 1) / side)
                for gx in 0..<side {
                    let x0 = width * gx / side, x1 = max(x0 + 1, width * (gx + 1) / side)
                    var sum = 0, n = 0
                    for y in y0..<min(y1, height) {
                        let row = base + y * stride
                        for x in x0..<min(x1, width) {
                            let p = row + x * 4
                            // Rough luma from BGRA. Exact coefficients do not
                            // matter — both sides of every comparison use this
                            // same function.
                            sum += (Int(p[0]) + 2 * Int(p[1]) + Int(p[2])) / 4
                            n += 1
                        }
                    }
                    cells[gy * side + gx] = n > 0 ? UInt8(min(255, sum / n)) : 0
                }
            }
        }
        return CanvasSignature(cells: cells, width: width, height: height)
    }

    /// How much variation the fingerprint holds, 0...1.
    ///
    /// THE BLANK-CANVAS PROBLEM: two brand-new documents are both pure white, so
    /// they match each other perfectly and with total confidence. Content is
    /// only evidence of identity when there is content — a featureless
    /// fingerprint must carry no weight at all, or every artist's second new
    /// drawing gets welded onto their first.
    var detail: Double {
        guard isValid else { return 0 }
        let mean = cells.reduce(0) { $0 + Double($1) } / Double(cells.count)
        let variance = cells.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(cells.count)
        return min(1, sqrt(variance) / 64)
    }

    /// Below this, a fingerprint is a blank sheet of paper and proves nothing.
    static let detailFloor = 0.04

    var isFeatureless: Bool { detail < CanvasSignature.detailFloor }

    /// Mean absolute difference, 0 (identical) ... 1 (opposite).
    ///
    /// Necessary but NOT sufficient for identity — see `similarity`. A canvas
    /// with one stroke on it differs from a canvas with one stroke somewhere
    /// else by very little, because both are almost entirely blank paper.
    static func distance(_ a: CanvasSignature, _ b: CanvasSignature) -> Double {
        guard a.isValid, b.isValid else { return 1 }
        let total = zip(a.cells, b.cells).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(a.cells.count * 255)
    }

    /// Correlation of the two fingerprints, -1 ... 1. This is what actually
    /// decides identity.
    ///
    /// It asks "is the ink in the SAME PLACES", independently of how much ink
    /// there is — which is exactly the question `distance` cannot answer on a
    /// sparse canvas. Measured on the synthetic canvases in the tests:
    ///
    ///   reopened untouched          dist 0.000  corr +1.00
    ///   same picture, halved        dist 0.013  corr +0.99
    ///   two strokes later           dist 0.005  corr +0.92
    ///   an evening's work later     dist 0.085  corr +0.80
    ///   a different drawing         dist 0.242  corr +0.03
    ///   two canvases, one stroke each, in different places
    ///                               dist 0.050  corr -0.04   <- the case that
    ///                               distance alone would have called identical.
    ///
    /// A featureless fingerprint has no variance to correlate, so this returns 0
    /// for a blank canvas rather than a false +1.
    static func similarity(_ a: CanvasSignature, _ b: CanvasSignature) -> Double {
        guard a.isValid, b.isValid else { return 0 }
        let x = a.cells.map(Double.init), y = b.cells.map(Double.init)
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        var num = 0.0, dx = 0.0, dy = 0.0
        for i in 0..<x.count {
            let p = x[i] - mx, q = y[i] - my
            num += p * q; dx += p * p; dy += q * q
        }
        guard dx > 0, dy > 0 else { return 0 }
        return num / (dx * dy).squareRoot()
    }
}

// MARK: - the session sidecar

/// What one recording session was, written beside its video by the encoder and
/// read by the app when it files that session into a drawing.
///
/// A WIRE FORMAT BETWEEN TWO PROCESSES, and therefore defined exactly once. It
/// was briefly declared in both the encoder and the app — the same hazard
/// FrameHeader carries a warning about, except that one is unavoidable (C on one
/// side, Swift on the other) and this one was not. LibraryCore is compiled into
/// both binaries, so here it is only true in one place.
struct SessionSidecar: Codable {
    var title: String
    var startedAt: Date
    var frames: Int
    var width: Int
    var height: Int
    var opening: CanvasSignature
    var closing: CanvasSignature
}

// MARK: - the model

/// One recording session, already encoded into its own playable video.
struct Piece: Codable, Equatable {
    /// File name only, never a path: pieces move between drawing folders when
    /// somebody regroups them, and a stored absolute path would go stale.
    var file: String
    var startedAt: Date
    var frames: Int
    var width: Int
    var height: Int
    /// What the canvas looked like at the start and end of this session.
    var opening: CanvasSignature
    var closing: CanvasSignature
}

/// One drawing: the thing an artist would call "my picture", across however many
/// evenings it took.
struct Drawing: Codable, Equatable {
    var id: String
    /// Display name and folder stem. A LABEL — renaming it never re-identifies
    /// anything, exactly as canvas names work inside a session.
    var title: String
    var folder: String
    /// Document path, when a future build can read one. Optional by design.
    var path: String?
    var pieces: [Piece]

    /// Pieces in capture order. Filing a three-week-old session into an existing
    /// drawing inserts it in the MIDDLE, not at the end — hence sorting on read
    /// rather than trusting append order.
    var ordered: [Piece] { pieces.sorted { $0.startedAt < $1.startedAt } }

    /// The state of the canvas when this drawing was last put down. What a new
    /// session's opening frame is compared against.
    var closing: CanvasSignature? { ordered.last?.closing }

    var lastDrawn: Date? { ordered.last?.startedAt }
    var totalFrames: Int { pieces.reduce(0) { $0 + $1.frames } }
}

/// The whole library. Serialised to JSON in Application Support; the videos
/// themselves are the real artefact, and this is only the bookkeeping that says
/// which belong together.
/// A session that looked like it might continue an existing drawing, filed as
/// its own drawing until somebody says otherwise.
///
/// It is NOT a blocked or half-finished state: the piece is filed, its video
/// exists, and leaving the question unanswered forever is a supported outcome.
/// The only cost of ignoring it is two rows in the library instead of one.
struct Pending: Codable, Equatable {
    /// The piece, as filed — the identity used by the ask-once rule.
    var pieceFile: String
    /// Where it went: a drawing of its own.
    var drawingId: String
    /// What it might belong to instead.
    var candidateId: String
    var askedAt: Date
}

struct Library: Codable, Equatable {
    var drawings: [Drawing] = []
    var pending: [Pending] = []
    /// "sessionFile|drawingId" pairs somebody has already said no to.
    ///
    /// Asking twice about the same pair is how a prompt becomes noise people
    /// dismiss without reading, which is worse than not asking: the one time it
    /// matters, they will click through it too.
    var declined: [String] = []

    static func declineKey(session: String, drawing: String) -> String { "\(session)|\(drawing)" }

    func hasDeclined(session: String, drawing: String) -> Bool {
        declined.contains(Library.declineKey(session: session, drawing: drawing))
    }
}

// MARK: - the ladder

enum Match: Equatable {
    /// Strong evidence. File it automatically, say so, move on.
    case same(String)
    /// Plausible. Record it as its own drawing and ASK — never merge on this.
    case ask(drawing: String, distance: Double)
    /// Nothing to go on. A new drawing, silently.
    case new
}

enum LibraryCore {

    /// Below this distance two canvases are the same drawing continued.
    ///
    /// Reopening a saved file redraws it from the same layer data, so a genuine
    /// continuation is usually near-identical; the tolerance covers a different
    /// mip level or canvas size between sessions, not real drawing.
    ///
    /// Measured against the synthetic canvases in tests/LibraryTests.swift:
    ///   reopened untouched   0.000
    ///   same picture, halved 0.013   <- must still auto-merge
    ///   an evening's work    0.069 … 0.085
    ///   another drawing      0.200 … 0.302
    static let sameDistance = 0.03

    /// Correlation required to merge automatically. This, not the distance, is
    /// the load-bearing test — see CanvasSignature.similarity.
    static let sameSimilarity = 0.90

    /// Correlation required to raise a question. Below it the two canvases have
    /// their ink in unrelated places and there is nothing to ask about.
    static let askSimilarity = 0.55

    /// Between `sameDistance` and this, it is worth asking about — an evening's
    /// work changes a canvas, so a continuation after real progress lands here
    /// rather than at zero.
    ///
    /// The ceiling is deliberate, not a limitation to fix: past it, the canvas
    /// no longer resembles what was left behind, and there is nothing left to
    /// base a claim of identity on. A session that repaints the whole canvas
    /// becomes its own drawing and gets filed by hand — which the library makes
    /// a one-click move.
    ///
    /// Loose (a different drawing measures 0.20…0.30) because `askSimilarity`
    /// does the discriminating; this only keeps a wildly different canvas out
    /// when the correlation happens to be flattering.
    static let askDistance = 0.20

    /// SAI names every new document "NewCanvas1", "NewCanvas2", … so the name
    /// says nothing about which drawing this is.
    static func isDefaultTitle(_ t: String) -> Bool {
        guard t.hasPrefix("NewCanvas") else { return false }
        let rest = t.dropFirst("NewCanvas".count)
        return rest.isEmpty || rest.allSatisfy(\.isNumber)
    }

    /// Which drawing, if any, does a session that OPENS like this belong to?
    ///
    /// `sessionFile` identifies the session for the ask-once rule; `candidates`
    /// is the whole library. Only drawings with a usable closing fingerprint can
    /// match, so a library of blank canvases matches nothing.
    static func classify(opening: CanvasSignature,
                         title: String,
                         path: String?,
                         candidates: [Drawing],
                         sessionFile: String,
                         declined: Library) -> Match {
        // 1. An exact document path is identity, and needs no pixels.
        if let path, !path.isEmpty,
           let hit = candidates.first(where: { $0.path == path }) {
            return .same(hit.id)
        }

        // Content is evidence only when there IS content. A blank opening frame
        // stops the ladder here rather than matching the first blank drawing in
        // the library — see CanvasSignature.detail.
        guard opening.isValid, !opening.isFeatureless else { return .new }

        // The best candidate is the one whose ink is in the most similar places,
        // not the one that merely differs least on average.
        var best: (drawing: Drawing, distance: Double, similarity: Double)?
        for d in candidates {
            guard let closing = d.closing, closing.isValid, !closing.isFeatureless else { continue }
            let sim = CanvasSignature.similarity(opening, closing)
            let dist = CanvasSignature.distance(opening, closing)
            if best == nil || sim > best!.similarity { best = (d, dist, sim) }
        }
        guard let best else { return .new }

        // 2. It looks like where that drawing was left off. Rename, move, Save
        //    As — none of them touch this.
        if best.similarity >= sameSimilarity && best.distance <= sameDistance {
            return .same(best.drawing.id)
        }

        // 3. Plausible, or the weaker title+size agreement. Worth a question,
        //    never worth a silent merge.
        //
        // SAI's own default names are excluded from that agreement: every
        // unsaved document is "NewCanvas1", so treating it as evidence would
        // raise a question about the wrong drawing nearly every time somebody
        // starts a fresh one — and a prompt that is usually wrong is a prompt
        // people learn to dismiss unread.
        let titleAgrees = !title.isEmpty && !isDefaultTitle(title) && title == best.drawing.title
            && opening.width == best.drawing.closing?.width
            && opening.height == best.drawing.closing?.height
        let contentPlausible = best.similarity >= askSimilarity && best.distance <= askDistance
        if contentPlausible || titleAgrees {
            guard !declined.hasDeclined(session: sessionFile, drawing: best.drawing.id) else { return .new }
            return .ask(drawing: best.drawing.id, distance: best.distance)
        }
        return .new
    }
}

// MARK: - naming

extension LibraryCore {
    /// Folder name for a drawing. Two drawings must never share a folder, so a
    /// clash is resolved by numbering rather than by merging them on disk —
    /// which is exactly the accident the whole ladder exists to prevent.
    static func folderName(title: String, taken: Set<String>) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var stem = title.components(separatedBy: bad).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A name of only dots would be "." or ".." on disk.
        if stem.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty { stem = "" }
        if stem.isEmpty { stem = "Drawing" }
        if stem.count > 60 { stem = String(stem.prefix(60)).trimmingCharacters(in: .whitespaces) }
        guard taken.contains(stem) else { return stem }
        var n = 2
        while taken.contains("\(stem) \(n)") { n += 1 }
        return "\(stem) \(n)"
    }

    /// File name for one session's piece. Sorts chronologically as text, which
    /// is what a file browser and the rebuild both want.
    static func pieceName(startedAt: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return "\(f.string(from: startedAt)).mp4"
    }

    /// Make a piece name unique inside its folder. A second session inside the
    /// same minute would otherwise overwrite the first — and pieces are the
    /// append-only archive, so overwriting one loses a whole session.
    static func uniquePieceName(startedAt: Date, taken: Set<String>) -> String {
        let base = pieceName(startedAt: startedAt)
        guard taken.contains(base) else { return base }
        let stem = String(base.dropLast(4))
        var n = 2
        while taken.contains("\(stem) (\(n)).mp4") { n += 1 }
        return "\(stem) (\(n)).mp4"
    }
}

// MARK: - mutations

extension Library {
    func drawing(id: String) -> Drawing? { drawings.first { $0.id == id } }

    /// A stable id that does not depend on the title (which changes) or on the
    /// canvas address (which is meaningless tomorrow).
    static func newId(startedAt: Date, salt: Int) -> String {
        String(format: "d%08x%02x", UInt32(truncatingIfNeeded: Int(startedAt.timeIntervalSince1970)), salt & 0xff)
    }

    mutating func addDrawing(title: String, path: String?, piece: Piece) -> String {
        let id = Library.newId(startedAt: piece.startedAt, salt: drawings.count)
        let folder = LibraryCore.folderName(title: title, taken: Set(drawings.map(\.folder)))
        drawings.append(Drawing(id: id, title: title, folder: folder, path: path, pieces: [piece]))
        return id
    }

    /// Append-only: attaching never rewrites an existing piece, it only adds one
    /// to the list. That is what makes a mis-filed session recoverable by moving
    /// a file rather than by un-merging a video.
    mutating func attach(_ piece: Piece, to id: String) {
        guard let i = drawings.firstIndex(where: { $0.id == id }) else { return }
        guard !drawings[i].pieces.contains(where: { $0.file == piece.file }) else { return }
        drawings[i].pieces.append(piece)
    }

    /// Move a piece between drawings — the regrouping escape hatch. Returns the
    /// piece's new file name, which may have been renamed to avoid a clash in
    /// the destination folder.
    @discardableResult
    mutating func movePiece(file: String, from: String, to: String) -> String? {
        guard let src = drawings.firstIndex(where: { $0.id == from }),
              let dst = drawings.firstIndex(where: { $0.id == to }), src != dst,
              let pi = drawings[src].pieces.firstIndex(where: { $0.file == file }) else { return nil }
        var piece = drawings[src].pieces.remove(at: pi)
        let taken = Set(drawings[dst].pieces.map(\.file))
        if taken.contains(piece.file) {
            piece.file = LibraryCore.uniquePieceName(startedAt: piece.startedAt, taken: taken)
        }
        drawings[dst].pieces.append(piece)
        // A drawing with no pieces left is not a drawing; leaving it behind
        // would litter the library with empty rows nobody can act on.
        if drawings[src].pieces.isEmpty { drawings.remove(at: src) }
        return piece.file
    }

    /// Split a piece out into a drawing of its own — the answer to "no, that was
    /// something else", available long after the question was asked.
    @discardableResult
    mutating func splitPiece(file: String, from: String, title: String) -> String? {
        guard let src = drawings.firstIndex(where: { $0.id == from }),
              let pi = drawings[src].pieces.firstIndex(where: { $0.file == file }) else { return nil }
        let piece = drawings[src].pieces.remove(at: pi)
        if drawings[src].pieces.isEmpty { drawings.remove(at: src) }
        return addDrawing(title: title, path: nil, piece: piece)
    }

    mutating func decline(session: String, drawing: String) {
        let k = Library.declineKey(session: session, drawing: drawing)
        if !declined.contains(k) { declined.append(k) }
    }
}

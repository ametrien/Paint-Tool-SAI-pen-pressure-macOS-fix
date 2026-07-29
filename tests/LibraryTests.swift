// LibraryTests.swift — unit tests for LibraryCore.swift.
//
// No AVFoundation, no SAI, no video: canvases are synthesised as BGRA buffers in
// memory, so the whole identity ladder is exercised without recording anything.
//
// Run:  bash tests/run-tests.sh

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (LibraryTests.swift:\(line))"); failures += 1 }
}

// MARK: - synthetic canvases

/// A blank white canvas — what every new document looks like.
func blankCanvas(w: Int = 200, h: Int = 150) -> Data {
    Data(repeating: 0xff, count: w * h * 4)
}

/// A canvas holding `strokes` dark marks. `seed` picks the picture; `strokes`
/// says how far along it is, so the same seed with more strokes models another
/// evening's work on the SAME drawing, and a different seed models a different
/// drawing entirely.
///
/// Two properties the fixture has to have, both learned the hard way:
///
///   * marks are placed as FRACTIONS of the canvas, so the same picture at
///     another size is genuinely that picture scaled — otherwise the resize test
///     is testing nothing.
///   * different seeds must look structurally different, not merely shifted. A
///     first version drew horizontal bands for every seed, which put "another
///     drawing" (0.108) and "same drawing, one evening later" (0.096) at
///     indistinguishable distances and made the thresholds untunable.
func drawnCanvas(w: Int = 200, h: Int = 150, seed: Int = 1, strokes: Int = 8) -> Data {
    var px = [UInt8](repeating: 0xff, count: w * h * 4)
    // bitPattern, not UInt64(_:): the multiply wraps negative and the checked
    // conversion would trap on it.
    var rng = UInt64(bitPattern: Int64(seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407))
    func next() -> Double {
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((rng >> 33) % 10_000) / 10_000
    }
    for _ in 0..<strokes {
        let cx = next(), cy = next()
        let rw = 0.08 + next() * 0.22, rh = 0.04 + next() * 0.18
        let x0 = Int(cx * Double(w)), y0 = Int(cy * Double(h))
        let x1 = min(w, x0 + max(1, Int(rw * Double(w))))
        let y1 = min(h, y0 + max(1, Int(rh * Double(h))))
        guard x0 < x1, y0 < y1 else { continue }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = (y * w + x) * 4
                px[o] = 0x28; px[o + 1] = 0x28; px[o + 2] = 0x28; px[o + 3] = 0xff
            }
        }
    }
    return Data(px)
}

/// A canvas holding a few SMALL marks — a drawing barely begun.
///
/// The point of this fixture is that two different sparse canvases are very
/// close by mean-absolute distance (almost all of both is blank paper) while
/// being completely uncorrelated. That combination is what the distance-only
/// version of the ladder got wrong, and nothing built from `drawnCanvas` can
/// produce it: its marks are too big.
func sparseCanvas(w: Int = 200, h: Int = 150, seed: Int, marks: Int = 3,
                  scale: Double = 0.06) -> Data {
    var px = [UInt8](repeating: 0xff, count: w * h * 4)
    var rng = UInt64(bitPattern: Int64(seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407))
    func next() -> Double {
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((rng >> 33) % 10_000) / 10_000
    }
    for _ in 0..<marks {
        let x0 = Int(next() * Double(w) * 0.9), y0 = Int(next() * Double(h) * 0.9)
        let x1 = min(w, x0 + max(1, Int(scale * Double(w))))
        let y1 = min(h, y0 + max(1, Int(scale * Double(h))))
        for y in y0..<y1 { for x in x0..<x1 {
            let o = (y * w + x) * 4
            px[o] = 0x28; px[o + 1] = 0x28; px[o + 2] = 0x28; px[o + 3] = 0xff
        } }
    }
    return Data(px)
}

func sig(_ d: Data, w: Int = 200, h: Int = 150) -> CanvasSignature {
    CanvasSignature.fingerprint(bgra: d, width: w, height: h, stride: w * 4)!
}

func piece(_ file: String, day: Int, opening: CanvasSignature, closing: CanvasSignature,
           frames: Int = 40) -> Piece {
    Piece(file: file,
          startedAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(day) * 86_400),
          frames: frames, width: opening.width, height: opening.height,
          opening: opening, closing: closing)
}

@main
struct LibraryTests {
    static func main() {

print("LibraryCore tests:")

// MARK: - fingerprints

do {
    let blank = sig(blankCanvas())
    let drawn = sig(drawnCanvas(seed: 1))
    expect(blank.isValid && drawn.isValid, "fingerprint: 16x16 of a canvas is produced")
    expect(CanvasSignature.fingerprint(bgra: Data(repeating: 0, count: 10),
                                       width: 200, height: 150, stride: 800) == nil,
           "fingerprint: a buffer too small for the stated size is refused")
    expect(CanvasSignature.fingerprint(bgra: blankCanvas(), width: 200, height: 150,
                                       stride: 100) == nil,
           "fingerprint: a stride narrower than a row is refused")

    expect(CanvasSignature.distance(drawn, drawn) == 0, "fingerprint: identical canvases are distance 0")
    expect(CanvasSignature.distance(drawn, sig(drawnCanvas(seed: 9))) > LibraryCore.askDistance,
           "fingerprint: two different drawings are far apart")

    // A canvas resized between sessions is still the same drawing, so the
    // fingerprint must be resolution-independent — and close enough to merge
    // automatically, not merely close enough to ask about.
    let small = CanvasSignature.fingerprint(bgra: drawnCanvas(w: 100, h: 75, seed: 1),
                                            width: 100, height: 75, stride: 400)!
    expect(CanvasSignature.distance(drawn, small) < LibraryCore.sameDistance,
           "fingerprint: the same drawing at another size still resembles itself")

    // THE TRAP: blankness. Delete the isFeatureless guard in classify() and the
    // blank-canvas test below goes red — this is the measurement it relies on.
    expect(blank.isFeatureless, "fingerprint: a blank canvas is featureless")
    expect(!drawn.isFeatureless, "fingerprint: a drawn canvas is not featureless")

    // THE TRAP THAT DISTANCE CANNOT CATCH: two canvases one stroke old, marked
    // in different places, are only 0.05 apart — closer than the same drawing
    // after an evening's work (0.085). Judge on distance alone and two unrelated
    // new drawings merge. Correlation is what separates them: -0.04 against
    // +0.80. Delete the similarity term from classify() and the barely-started
    // case below goes red.
    let oneStroke = sig(drawnCanvas(seed: 4, strokes: 1))
    let otherOneStroke = sig(drawnCanvas(seed: 11, strokes: 1))
    expect(CanvasSignature.distance(oneStroke, otherOneStroke) < LibraryCore.askDistance,
           "fingerprint: two sparse canvases are close by distance — which is why distance is not enough")
    expect(CanvasSignature.similarity(oneStroke, otherOneStroke) < LibraryCore.askSimilarity,
           "fingerprint: …but uncorrelated, which is what catches them")
    expect(CanvasSignature.similarity(drawn, drawn) > 0.99,
           "fingerprint: a canvas correlates with itself")
    expect(CanvasSignature.similarity(blank, blank) < LibraryCore.askSimilarity,
           "fingerprint: a blank canvas does not correlate with another blank one")
    expect(CanvasSignature.similarity(drawn, sig(drawnCanvas(seed: 1, strokes: 14)))
           >= LibraryCore.askSimilarity,
           "fingerprint: an evening's work still correlates with where it started")
}

// MARK: - the ladder

let mondayNight = sig(drawnCanvas(seed: 1, strokes: 8))     // where we left off
let tuesdayStart = sig(drawnCanvas(seed: 1, strokes: 8))    // reopened, untouched
let tuesdayEnd = sig(drawnCanvas(seed: 1, strokes: 14))     // an evening's work later
let otherDrawing = sig(drawnCanvas(seed: 9, strokes: 8))

func libraryWithSketch(title: String = "Sketch", path: String? = nil) -> Library {
    var lib = Library()
    _ = lib.addDrawing(title: title, path: path,
                       piece: piece("2026-07-27 2015.mp4", day: 0,
                                    opening: sig(blankCanvas()), closing: mondayNight))
    return lib
}

do {
    let lib = libraryWithSketch()
    let id = lib.drawings[0].id

    expect(LibraryCore.classify(opening: tuesdayStart, title: "Sketch", path: nil,
                                candidates: lib.drawings, sessionFile: "s.mp4",
                                declined: lib) == .same(id),
           "ladder: reopening a drawing continues it")

    // THE QUESTION THAT STARTED THIS: the artist renamed the canvas. Match on
    // the title instead of on the pixels and this goes red.
    expect(LibraryCore.classify(opening: tuesdayStart, title: "final FINAL v3", path: nil,
                                candidates: lib.drawings, sessionFile: "s.mp4",
                                declined: lib) == .same(id),
           "ladder: a renamed canvas is still the same drawing")

    // THE TRAP: two brand-new documents are both pure white and match perfectly.
    // Remove the featureless guard and this welds them together.
    var blankLib = Library()
    _ = blankLib.addDrawing(title: "NewCanvas1", path: nil,
                            piece: piece("a.mp4", day: 0, opening: sig(blankCanvas()),
                                         closing: sig(blankCanvas())))
    expect(LibraryCore.classify(opening: sig(blankCanvas()), title: "NewCanvas1", path: nil,
                                candidates: blankLib.drawings, sessionFile: "b.mp4",
                                declined: blankLib) == .new,
           "ladder: two blank canvases are NOT the same drawing")

    // THE TRAP THE ABOVE CANNOT SET: two barely-begun canvases whose marks are
    // small enough that they are also CLOSE by distance — 0.019, well inside
    // sameDistance — while being uncorrelated at -0.03. Only the correlation
    // term in the `.same` branch stands between this and two unrelated drawings
    // being merged automatically, with no question asked. Delete it and this
    // goes red; every other blankness test stays green.
    var sparseLib = Library()
    _ = sparseLib.addDrawing(title: "NewCanvas1", path: nil,
                             piece: piece("a.mp4", day: 0, opening: sig(blankCanvas()),
                                          closing: sig(sparseCanvas(seed: 4))))
    expect(CanvasSignature.distance(sig(sparseCanvas(seed: 4)), sig(sparseCanvas(seed: 11)))
           < LibraryCore.sameDistance,
           "ladder: two barely-begun canvases are inside the auto-merge DISTANCE…")
    expect(LibraryCore.classify(opening: sig(sparseCanvas(seed: 11)), title: "NewCanvas1",
                                path: nil, candidates: sparseLib.drawings,
                                sessionFile: "b.mp4", declined: sparseLib) == .new,
           "ladder: …and are still not merged, because they do not correlate")

    // THE TRAP FOR THE FEATURELESS GUARD ITSELF: two canvases each holding one
    // faint speck in the SAME place — someone's first mark landing centre-canvas
    // twice. Distance 0.000 and correlation +1.000, so both content tests say
    // "identical" with total confidence; only the detail floor refuses. There is
    // not enough on either canvas to claim anything. Remove the isFeatureless
    // guards, or set detailFloor to 0, and this goes red.
    let faint = sig(sparseCanvas(seed: 4, marks: 1, scale: 0.02))
    var faintLib = Library()
    _ = faintLib.addDrawing(title: "NewCanvas1", path: nil,
                            piece: piece("a.mp4", day: 0, opening: sig(blankCanvas()),
                                         closing: faint))
    expect(CanvasSignature.similarity(faint, faint) > 0.99
           && CanvasSignature.distance(faint, faint) == 0,
           "ladder: one faint speck matches itself perfectly on both measures…")
    expect(LibraryCore.classify(opening: faint, title: "NewCanvas1", path: nil,
                                candidates: faintLib.drawings, sessionFile: "b.mp4",
                                declined: faintLib) == .new,
           "ladder: …and is still refused, as too little to judge on")

    // …and the same for a canvas that is nearly blank rather than exactly
    // blank: two drawings each one stroke old, in different places. This is the
    // case that pins CanvasSignature.detailFloor — literal white would still be
    // rejected with the floor set to zero, but these would silently merge, and
    // "I made two new drawings tonight" is the most ordinary thing in the world.
    var barely = Library()
    _ = barely.addDrawing(title: "NewCanvas1", path: nil,
                          piece: piece("a.mp4", day: 0, opening: sig(blankCanvas()),
                                       closing: sig(drawnCanvas(seed: 4, strokes: 1))))
    expect(LibraryCore.classify(opening: sig(drawnCanvas(seed: 11, strokes: 1)),
                                title: "NewCanvas1", path: nil,
                                candidates: barely.drawings, sessionFile: "b.mp4",
                                declined: barely) == .new,
           "ladder: two barely-started canvases are NOT the same drawing")

    // Same default title, same size, genuinely different pictures. SAI calls
    // every new document NewCanvas1, so the name must not even raise a question.
    var defaults = Library()
    _ = defaults.addDrawing(title: "NewCanvas1", path: nil,
                            piece: piece("a.mp4", day: 0, opening: sig(blankCanvas()),
                                         closing: otherDrawing))
    expect(LibraryCore.classify(opening: tuesdayStart, title: "NewCanvas1", path: nil,
                                candidates: defaults.drawings, sessionFile: "b.mp4",
                                declined: defaults) == .new,
           "ladder: SAI's default name is not evidence of anything")

    // Two different drawings that share a name the ARTIST chose: worth asking
    // about, never worth merging.
    var named = Library()
    _ = named.addDrawing(title: "Sketch", path: nil,
                         piece: piece("a.mp4", day: 0, opening: sig(blankCanvas()),
                                      closing: otherDrawing))
    if case .ask = LibraryCore.classify(opening: tuesdayStart, title: "Sketch", path: nil,
                                        candidates: named.drawings, sessionFile: "b.mp4",
                                        declined: named) {
        expect(true, "ladder: two drawings sharing a chosen name ask rather than merge")
    } else {
        expect(false, "ladder: two drawings sharing a chosen name ask rather than merge")
    }

    // A completely unrelated drawing, no name in common: no question at all.
    expect(LibraryCore.classify(opening: otherDrawing, title: "Other", path: nil,
                                candidates: lib.drawings, sessionFile: "s.mp4",
                                declined: lib) == .new,
           "ladder: an unrelated drawing starts its own entry silently")

    // The path, when a future build can read one, outranks the pixels.
    let pathLib = libraryWithSketch(path: "/Users/a/art/sketch.sai2")
    expect(LibraryCore.classify(opening: otherDrawing, title: "anything",
                                path: "/Users/a/art/sketch.sai2",
                                candidates: pathLib.drawings, sessionFile: "s.mp4",
                                declined: pathLib) == .same(pathLib.drawings[0].id),
           "ladder: a matching document path is identity on its own")
}

// MARK: - which candidate wins

do {
    // Two candidates, and the two measures disagree about which is closer. Built
    // from explicit fingerprints because ordinary canvases rarely separate the
    // two rankings — which is exactly why this line would otherwise rot unpinned.
    //
    //   the RIGHT answer: the same picture, rendered at half strength — a
    //   lower-opacity layer, or a background that was hidden when the file was
    //   reopened. Correlates perfectly (+1.00), but EVERY inked cell differs, so
    //   its distance is the larger of the two.
    //   the decoy: a different drawing that happens to share part of that ink
    //   and has less of its own. Fewer cells differ, so it is nearer by
    //   distance, while correlating distinctly worse.
    //
    // Rank by distance and the decoy wins. Rank by correlation and the real
    // drawing does.
    func signature(_ cells: [UInt8]) -> CanvasSignature {
        CanvasSignature(cells: cells, width: 200, height: 150)
    }
    let n = CanvasSignature.side * CanvasSignature.side
    var pattern = [UInt8](repeating: 255, count: n)
    for i in 0..<n where (i / 16 + i % 16) % 3 == 0 { pattern[i] = 40 }
    // Same picture at half strength: correlation 1, distance large.
    let dimmed = signature(pattern.map { UInt8(255 - (255 - Int($0)) / 2) })
    // Shares 60% of the ink, has none of its own: nearer, correlates worse.
    var partial = pattern
    for i in 0..<n where pattern[i] != 255 && i % 5 < 2 { partial[i] = 255 }

    var lib = Library()
    let right = lib.addDrawing(title: "Portrait", path: nil,
                               piece: piece("p.mp4", day: 0, opening: signature(pattern),
                                            closing: dimmed))
    let decoy = lib.addDrawing(title: "Doodle", path: nil,
                               piece: piece("q.mp4", day: 1, opening: signature(partial),
                                            closing: signature(partial)))
    let opening = signature(pattern)
    expect(CanvasSignature.distance(opening, signature(partial))
           < CanvasSignature.distance(opening, dimmed),
           "candidate: the decoy really is nearer by distance")
    expect(CanvasSignature.similarity(opening, dimmed)
           > CanvasSignature.similarity(opening, signature(partial)),
           "candidate: …and the real drawing really does correlate better")

    switch LibraryCore.classify(opening: opening, title: "Portrait", path: nil,
                                candidates: lib.drawings, sessionFile: "s.mp4",
                                declined: lib) {
    case .same(let id), .ask(let id, _):
        expect(id == right,
               "candidate: the drawing that correlates wins, not the one that is merely near")
        expect(id != decoy, "candidate: and the decoy does not")
    case .new:
        expect(false, "candidate: the drawing that correlates wins, not the one that is merely near")
    }
}

// MARK: - asking once

do {
    var lib = libraryWithSketch()
    _ = lib.addDrawing(title: "Something else", path: nil,
                       piece: piece("x.mp4", day: 1, opening: sig(blankCanvas()),
                                    closing: otherDrawing))
    // Far enough to be a question, not far enough to be certain.
    let progressed = tuesdayEnd
    guard case .ask(let asked, _) = LibraryCore.classify(
        opening: progressed, title: "Sketch", path: nil, candidates: lib.drawings,
        sessionFile: "tonight.mp4", declined: lib) else {
        expect(false, "ask: a session after real progress raises a question"); exit(1)
    }
    expect(true, "ask: a session after real progress raises a question")

    // THE TRAP: a prompt that reappears after "no" is one people learn to
    // dismiss unread. Drop the declined check and this goes red.
    lib.decline(session: "tonight.mp4", drawing: asked)
    expect(LibraryCore.classify(opening: progressed, title: "Sketch", path: nil,
                                candidates: lib.drawings, sessionFile: "tonight.mp4",
                                declined: lib) == .new,
           "ask: saying no is remembered, and never asked again")

    // …but only for that pair. Another session must still be able to ask.
    if case .ask = LibraryCore.classify(opening: progressed, title: "Sketch", path: nil,
                                        candidates: lib.drawings, sessionFile: "another.mp4",
                                        declined: lib) {
        expect(true, "ask: declining one session does not silence the next")
    } else {
        expect(false, "ask: declining one session does not silence the next")
    }
}

// MARK: - naming

do {
    expect(LibraryCore.folderName(title: "Sketch", taken: []) == "Sketch",
           "naming: a plain title is its own folder")
    expect(!LibraryCore.folderName(title: "a/b:c", taken: []).contains("/"),
           "naming: path separators are stripped")
    expect(LibraryCore.folderName(title: "   ", taken: []) == "Drawing",
           "naming: an empty title falls back")
    expect(LibraryCore.folderName(title: "..", taken: []) == "Drawing",
           "naming: a name of only dots does not become a directory traversal")

    // THE TRAP: two drawings in one folder would interleave their pieces and
    // rebuild into a single video containing both. Remove the uniquing and this
    // goes red.
    expect(LibraryCore.folderName(title: "Sketch", taken: ["Sketch"]) == "Sketch 2",
           "naming: a second drawing with the same title gets its own folder")
    expect(LibraryCore.folderName(title: "Sketch", taken: ["Sketch", "Sketch 2"]) == "Sketch 3",
           "naming: and a third")

    let t = Date(timeIntervalSince1970: 1_750_000_000)
    let name = LibraryCore.pieceName(startedAt: t)
    expect(name.hasSuffix(".mp4") && name.count > 8, "naming: a piece is named for when it was drawn")
    let later = LibraryCore.pieceName(startedAt: t.addingTimeInterval(86_400))
    expect(name < later, "naming: piece names sort chronologically as text")

    // THE TRAP: pieces are the append-only archive. Two sessions inside one
    // minute sharing a name would silently overwrite a whole evening's work.
    expect(LibraryCore.uniquePieceName(startedAt: t, taken: [name]) != name,
           "naming: a second session in the same minute does not overwrite the first")
}

// MARK: - the model

do {
    var lib = libraryWithSketch()
    let id = lib.drawings[0].id
    lib.attach(piece("2026-07-29 2141.mp4", day: 2, opening: tuesdayStart, closing: tuesdayEnd), to: id)
    expect(lib.drawing(id: id)?.pieces.count == 2, "model: attaching adds a piece")
    lib.attach(piece("2026-07-29 2141.mp4", day: 2, opening: tuesdayStart, closing: tuesdayEnd), to: id)
    expect(lib.drawing(id: id)?.pieces.count == 2, "model: attaching the same piece twice is a no-op")

    // Filing an OLD session into a drawing puts it in the middle, so order can
    // never be taken from append order.
    lib.attach(piece("2026-07-28 0900.mp4", day: 1, opening: mondayNight, closing: mondayNight), to: id)
    expect(lib.drawing(id: id)?.ordered.map(\.file) == ["2026-07-27 2015.mp4",
                                                       "2026-07-28 0900.mp4",
                                                       "2026-07-29 2141.mp4"],
           "model: pieces are ordered by when they were drawn, not when they were filed")
    expect(lib.drawing(id: id)?.closing == tuesdayEnd,
           "model: a drawing's closing state comes from its LAST piece by date")
}

do {
    // Regrouping: the escape hatch that makes asking safe.
    var lib = Library()
    let a = lib.addDrawing(title: "Sketch", path: nil,
                           piece: piece("2026-07-27 2015.mp4", day: 0,
                                        opening: sig(blankCanvas()), closing: mondayNight))
    let b = lib.addDrawing(title: "Portrait", path: nil,
                           piece: piece("2026-07-28 1000.mp4", day: 1,
                                        opening: sig(blankCanvas()), closing: otherDrawing))
    lib.attach(piece("2026-07-29 2141.mp4", day: 2, opening: tuesdayStart, closing: tuesdayEnd), to: a)

    expect(lib.movePiece(file: "2026-07-29 2141.mp4", from: a, to: b) == "2026-07-29 2141.mp4",
           "regroup: a mis-filed session moves to the right drawing")
    expect(lib.drawing(id: a)?.pieces.count == 1 && lib.drawing(id: b)?.pieces.count == 2,
           "regroup: the piece leaves one drawing and joins the other")

    // THE TRAP: moving into a folder that already holds that file name would
    // overwrite a session on disk. The rename is what stops it.
    var clash = Library()
    let c1 = clash.addDrawing(title: "One", path: nil,
                              piece: piece("2026-07-27 2015.mp4", day: 0,
                                           opening: sig(blankCanvas()), closing: mondayNight))
    let c2 = clash.addDrawing(title: "Two", path: nil,
                              piece: piece("2026-07-27 2015.mp4", day: 0,
                                           opening: sig(blankCanvas()), closing: otherDrawing))
    clash.attach(piece("2026-07-28 0900.mp4", day: 1, opening: mondayNight, closing: mondayNight), to: c1)
    let renamed = clash.movePiece(file: "2026-07-27 2015.mp4", from: c1, to: c2)
    expect(renamed != nil && renamed != "2026-07-27 2015.mp4",
           "regroup: a name clash in the destination renames instead of overwriting")
    expect(Set(clash.drawing(id: c2)?.pieces.map(\.file) ?? []).count == 2,
           "regroup: both sessions survive the move")

    // A drawing with nothing left in it is not a drawing.
    var empties = Library()
    let e1 = empties.addDrawing(title: "Doomed", path: nil,
                                piece: piece("p.mp4", day: 0, opening: sig(blankCanvas()),
                                             closing: mondayNight))
    let e2 = empties.addDrawing(title: "Keeper", path: nil,
                                piece: piece("q.mp4", day: 1, opening: sig(blankCanvas()),
                                             closing: otherDrawing))
    _ = empties.movePiece(file: "p.mp4", from: e1, to: e2)
    expect(empties.drawings.count == 1 && empties.drawings[0].id == e2,
           "regroup: a drawing left with no pieces disappears")

    // Splitting: "no, that was something else", answered a week late.
    var split = Library()
    let s = split.addDrawing(title: "Sketch", path: nil,
                             piece: piece("first.mp4", day: 0, opening: sig(blankCanvas()),
                                          closing: mondayNight))
    split.attach(piece("wrong.mp4", day: 1, opening: otherDrawing, closing: otherDrawing), to: s)
    let newId = split.splitPiece(file: "wrong.mp4", from: s, title: "Actually separate")
    expect(newId != nil && split.drawings.count == 2,
           "regroup: a piece can be split out into its own drawing later")
    expect(split.drawing(id: s)?.pieces.count == 1,
           "regroup: splitting removes it from the original")
}

// MARK: - persistence

do {
    var lib = libraryWithSketch()
    lib.decline(session: "s.mp4", drawing: lib.drawings[0].id)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let round = try? dec.decode(Library.self, from: enc.encode(lib))
    expect(round == lib, "persistence: the library round-trips through JSON unchanged")
    // Fingerprints live in the index forever, so their size is a real cost.
    let bytes = (try? enc.encode(lib))?.count ?? 0
    expect(bytes < 8_000, "persistence: one drawing costs well under 8 KB of index")
}

if failures > 0 {
    print("FAILED: \(failures) test(s)")
    exit(1)
}
print("All LibraryCore tests passed.")
    }
}

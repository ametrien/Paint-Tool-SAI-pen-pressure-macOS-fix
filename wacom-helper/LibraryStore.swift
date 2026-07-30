// LibraryStore.swift — the filesystem side of the timelapse library.
//
// LibraryCore decides WHAT belongs with what; this moves the files, keeps the
// index, and drives the encoder's --rebuild. The split is the same one the rest
// of the project uses: the decisions are pure and unit-tested, and the part that
// touches disk is thin enough to read in one sitting.
//
// LAYOUT ON DISK
//
//   ~/Movies/SAI Timelapses/
//     .recording/                  staging: this session's segments, hidden
//     Sketch/
//       Sketch.mp4                 the combined video. DERIVED — delete it and
//                                  it comes back on the next rebuild.
//       pieces/
//         2026-07-27 2015.mp4      one session. APPEND-ONLY: never rewritten,
//         2026-07-28 1903.mp4      never consumed by a rebuild.
//
// Why the split matters: extending one growing video each session would rewrite
// the file holding every previous evening every time somebody draws. Here a
// session adds exactly one new file and touches nothing that already exists, so
// the worst a failure can cost is the session that failed.

import Foundation

final class LibraryStore {
    let videosDir: String
    let indexPath: String
    private(set) var lib = Library()

    init(videosDir: String, indexPath: String) {
        self.videosDir = videosDir
        self.indexPath = indexPath
        load()
    }

    // MARK: - persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// True when the index on disk could not be read and this one was rebuilt
    /// from the folders instead.
    private(set) var recoveredFromBrokenIndex = false

    func load() {
        let url = URL(fileURLWithPath: indexPath)
        guard let data = try? Data(contentsOf: url) else { return }   // no index yet
        if let l = try? LibraryStore.decoder.decode(Library.self, from: data) {
            lib = l
            return
        }
        // THE INDEX IS THERE AND UNREADABLE. Doing nothing here was a quiet
        // disaster: `lib` stayed empty, and the next save() wrote that emptiness
        // over the only record of which sessions belong to which drawing. One
        // truncated write — a full disk, a power cut mid-save — and every
        // grouping was gone for good while the videos sat there unlinked.
        //
        // So: keep the unreadable file, and rebuild what the folders themselves
        // can tell us. A drawing's folder holds its pieces; that recovers the
        // grouping and the videos. What it cannot recover is the fingerprints,
        // and that is the right thing to lose — a recovered drawing simply stops
        // matching new sessions automatically until it is drawn on again.
        let aside = indexPath + ".broken"
        try? FileManager.default.removeItem(atPath: aside)
        try? FileManager.default.moveItem(atPath: indexPath, toPath: aside)
        lib = LibraryStore.recover(from: videosDir)
        recoveredFromBrokenIndex = true
        if !lib.drawings.isEmpty { save() }
    }

    /// Rebuild an index from what is on disk: every folder holding a `pieces`
    /// directory with videos in it is a drawing.
    static func recover(from videosDir: String) -> Library {
        let fm = FileManager.default
        var out = Library()
        let names = ((try? fm.contentsOfDirectory(atPath: videosDir)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for name in names {
            let folder = URL(fileURLWithPath: videosDir).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let piecesDir = folder.appendingPathComponent("pieces")
            let files = ((try? fm.contentsOfDirectory(atPath: piecesDir.path)) ?? [])
                .filter { $0.hasSuffix(".mp4") && !$0.hasPrefix(".") }
                .sorted()
            guard !files.isEmpty else { continue }
            // An all-zero fingerprint is deliberately INVALID, so the identity
            // ladder skips a recovered drawing rather than matching everything
            // against a canvas of nothing.
            let blank = CanvasSignature(cells: [], width: 0, height: 0)
            let pieces = files.map { f -> Piece in
                let url = piecesDir.appendingPathComponent(f)
                let when = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date(timeIntervalSince1970: 0)
                return Piece(file: f, startedAt: when, frames: 0, width: 0, height: 0,
                             opening: blank, closing: blank)
            }
            var d = Drawing(id: Library.newId(startedAt: pieces[0].startedAt,
                                              salt: out.drawings.count),
                            title: name, folder: name, path: nil, pieces: pieces)
            d.pieces = pieces
            out.drawings.append(d)
        }
        return out
    }

    /// Written atomically: the index is the only record of which sessions belong
    /// together, and a half-written one would scatter a drawing back into
    /// unrelated pieces.
    func save() {
        guard let data = try? LibraryStore.encoder.encode(lib) else { return }
        try? data.write(to: URL(fileURLWithPath: indexPath), options: .atomic)
    }

    // MARK: - paths

    var stagingDir: String { videosDir + "/.recording" }
    func folderURL(_ d: Drawing) -> URL {
        URL(fileURLWithPath: videosDir).appendingPathComponent(d.folder)
    }
    func piecesURL(_ d: Drawing) -> URL { folderURL(d).appendingPathComponent("pieces") }
    /// The combined video. Named after the drawing so a folder opened in Finder
    /// explains itself without the app.
    func videoURL(_ d: Drawing) -> URL {
        folderURL(d).appendingPathComponent("\(d.folder).mp4")
    }

    // MARK: - filing

    struct Filed {
        let drawingId: String
        let title: String
        let pieceFile: String
        /// Set when this looked like a continuation but not certainly enough to
        /// merge on its own — the library will ask.
        let askAbout: String?
    }

    /// Take the finished pieces the encoder left in staging and put each one
    /// where it belongs. Returns what happened, for the caller to report.
    ///
    /// Order matters here: the file is only moved after the index has decided
    /// where it goes, and the index is only saved after every move has been
    /// attempted — so a crash leaves either a piece still in staging (picked up
    /// next time) or a piece filed and recorded, never a piece recorded in a
    /// place it isn't.
    @discardableResult
    func fileFinishedSessions() -> [Filed] {
        let fm = FileManager.default
        let staging = stagingDir
        let names = ((try? fm.contentsOfDirectory(atPath: staging)) ?? [])
            .filter { $0.hasSuffix(".mp4") }
            .filter { n in
                // Numbered files are unfinished segments — --finalize has not
                // stitched them yet, and filing one would file a fragment.
                let parts = n.dropLast(4).split(separator: ".")
                return !(parts.count >= 2 && Int(parts[parts.count - 1]) != nil)
            }
            .sorted()

        var filed: [Filed] = []
        for n in names {
            let mp4 = URL(fileURLWithPath: staging).appendingPathComponent(n)
            let sidecarURL = mp4.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: sidecarURL),
                  let side = try? LibraryStore.decoder.decode(SessionSidecar.self, from: data)
            else { continue }        // no fingerprints: leave it for a human

            let piece = Piece(file: "", startedAt: side.startedAt, frames: side.frames,
                              width: side.width, height: side.height,
                              opening: side.opening, closing: side.closing)
            let match = LibraryCore.classify(opening: side.opening, title: side.title,
                                             path: nil, candidates: lib.drawings,
                                             sessionFile: n, declined: lib)

            var target: String
            var askAbout: String?
            var filedName: String
            switch match {
            case .same(let id):
                // Joins an existing drawing, so the name is chosen against what
                // that folder already holds.
                filedName = LibraryCore.uniquePieceName(
                    startedAt: side.startedAt,
                    taken: Set(lib.drawing(id: id)?.pieces.map(\.file) ?? []))
                var p = piece; p.file = filedName
                lib.attach(p, to: id)
                // Follow the canvas's current name. Save an untitled drawing and
                // SAI stops calling it NewCanvas1 — the drawing is the same one,
                // so it should stop being LABELLED NewCanvas1 too. Only a real
                // name replaces the old one: SAI's own default is not an
                // improvement on whatever is there, and the folder keeps the name
                // it was created with either way, so nothing moves on disk.
                if !side.title.isEmpty, !LibraryCore.isDefaultTitle(side.title),
                   let i = lib.drawings.firstIndex(where: { $0.id == id }),
                   lib.drawings[i].title != side.title {
                    lib.drawings[i].title = side.title
                }
                target = id
            case .new, .ask:
                // A drawing of its own, in a folder of its own — nothing to
                // clash with. `.ask` differs only in that a question is
                // recorded; it is never a silent merge.
                filedName = LibraryCore.pieceName(startedAt: side.startedAt)
                var p = piece; p.file = filedName
                target = lib.addDrawing(title: side.title, path: nil, piece: p)
                if case .ask(let candidate, _) = match { askAbout = candidate }
            }
            guard let drawing = lib.drawing(id: target) else { continue }

            let dest = piecesURL(drawing).appendingPathComponent(filedName)
            try? fm.createDirectory(at: piecesURL(drawing), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            do { try fm.moveItem(at: mp4, to: dest) }
            catch {
                // The move failed, so the index must not claim the piece is
                // there. Roll the entry back rather than leaving a drawing
                // pointing at a file that does not exist.
                rollBack(pieceFile: filedName, from: target)
                continue
            }
            try? fm.removeItem(at: sidecarURL)

            if let candidate = askAbout {
                lib.pending.append(Pending(pieceFile: filedName, drawingId: target,
                                           candidateId: candidate, askedAt: Date()))
            }
            filed.append(Filed(drawingId: target, title: drawing.title,
                               pieceFile: filedName, askAbout: askAbout))
        }
        if !filed.isEmpty { save() }
        return filed
    }

    private func rollBack(pieceFile: String, from id: String) {
        guard let i = lib.drawings.firstIndex(where: { $0.id == id }) else { return }
        lib.drawings[i].pieces.removeAll { $0.file == pieceFile }
        if lib.drawings[i].pieces.isEmpty { lib.drawings.remove(at: i) }
    }

    // MARK: - answering the question

    /// "Yes, same drawing." Moves the piece across, on disk and in the index.
    func confirmSame(_ p: Pending) {
        guard let from = lib.drawing(id: p.drawingId),
              let to = lib.drawing(id: p.candidateId) else { dropPending(p); return }
        let src = piecesURL(from).appendingPathComponent(p.pieceFile)
        guard let newName = lib.movePiece(file: p.pieceFile, from: p.drawingId, to: p.candidateId)
        else { dropPending(p); return }
        let fm = FileManager.default
        let dst = piecesURL(to).appendingPathComponent(newName)
        try? fm.createDirectory(at: piecesURL(to), withIntermediateDirectories: true)
        try? fm.moveItem(at: src, to: dst)
        // The source drawing may now be gone; if it is, its folder is an empty
        // shell and its derived video is of nothing.
        if lib.drawing(id: p.drawingId) == nil { try? fm.removeItem(at: folderURL(from)) }
        dropPending(p)
        save()
    }

    /// "No, different drawing." Remembered, so this pair is never asked about
    /// again — a prompt that reappears after an answer is one people learn to
    /// dismiss unread.
    func confirmSeparate(_ p: Pending) {
        lib.decline(session: p.pieceFile, drawing: p.candidateId)
        dropPending(p)
        save()
    }

    private func dropPending(_ p: Pending) {
        lib.pending.removeAll { $0.pieceFile == p.pieceFile && $0.candidateId == p.candidateId }
    }

    // MARK: - regrouping, after the fact

    func split(pieceFile: String, from id: String, title: String) {
        guard let src = lib.drawing(id: id) else { return }
        let srcURL = piecesURL(src).appendingPathComponent(pieceFile)
        guard let newId = lib.splitPiece(file: pieceFile, from: id, title: title),
              let dst = lib.drawing(id: newId) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: piecesURL(dst), withIntermediateDirectories: true)
        try? fm.moveItem(at: srcURL, to: piecesURL(dst).appendingPathComponent(pieceFile))
        if lib.drawing(id: id) == nil { try? fm.removeItem(at: folderURL(src)) }
        save()
    }

    func rename(_ id: String, to title: String) {
        guard let i = lib.drawings.firstIndex(where: { $0.id == id }) else { return }
        lib.drawings[i].title = title
        save()
    }

    /// Delete a drawing outright: its pieces, its video, its folder. The only
    /// call here that destroys anything the artist cannot get back, which is why
    /// it is one obvious function rather than a flag on another one.
    func delete(_ id: String) {
        guard let d = lib.drawing(id: id) else { return }
        try? FileManager.default.removeItem(at: folderURL(d))
        lib.drawings.removeAll { $0.id == id }
        lib.pending.removeAll { $0.drawingId == id || $0.candidateId == id }
        save()
    }

    // MARK: - rebuilding

    /// Rebuild one drawing's combined video from its pieces. Cheap (the encoder
    /// copies the H.264 samples rather than re-encoding them) and safe to call
    /// as often as you like.
    @discardableResult
    func rebuild(_ id: String, encoder: String) -> Bool {
        guard let d = lib.drawing(id: id) else { return false }
        guard FileManager.default.isExecutableFile(atPath: encoder) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: encoder)
        p.arguments = ["--rebuild", piecesURL(d).path, "--out", videoURL(d).path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// A length-capped copy for posting. Deliberately a SEPARATE file: the
    /// combined video stays full length and lossless, so capping never compounds
    /// across sessions the way re-timing an accumulating video would.
    @discardableResult
    func export(_ id: String, seconds: Int, to out: URL, encoder: String) -> Bool {
        guard let d = lib.drawing(id: id) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: encoder)
        var args = ["--rebuild", piecesURL(d).path, "--out", out.path]
        if seconds > 0 { args += ["--max-seconds", "\(seconds)"] }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

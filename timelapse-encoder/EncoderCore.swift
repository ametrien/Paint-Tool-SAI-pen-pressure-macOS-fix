// EncoderCore.swift — the PURE logic of the timelapse encoder, extracted so it
// can be unit-tested with no AVFoundation, no frame files and no SAI. main.swift
// keeps only the parts that need AVFoundation and the filesystem.
//
// Everything here is deterministic input -> output. If you change behaviour
// here, add/adjust a case in tests/EncoderTests.swift.

import Foundation

/// Header the DLL writes in front of every frame. Mirrors TL_FRAME_HDR in
/// wintab-src/timelapse_win.h — if one side changes, both must.
///
/// Layout (little-endian, no padding): magic[8], width, height, stride, format
/// as UInt32, then seq and tickMs as UInt64. 40 bytes total.
struct FrameHeader: Equatable {
    static let byteCount = 112
    static let magic = "SAITLF2"

    let width: Int
    let height: Int
    let stride: Int
    let format: UInt32       // 0 = BGRA8
    let seq: UInt64
    let tickMs: UInt64
    /// Canvas struct address. STABLE IDENTITY for one document: SAI allocates a
    /// canvas once and never moves it. Deliberately not the name — renaming a
    /// canvas would otherwise split its recording in two, and two canvases
    /// sharing a name would merge into one video.
    let canvasId: UInt64
    /// Display label only, used to name the output file. Last one seen wins, so
    /// renaming mid-session simply relabels the finished video.
    let name: String

    /// Returns nil rather than throwing for a bad header: a partially written
    /// file is an expected condition while recording is live, not an error.
    static func parse(_ d: Data) -> FrameHeader? {
        guard d.count >= byteCount else { return nil }
        let magicBytes = d.prefix(8).prefix(while: { $0 != 0 })
        guard String(decoding: magicBytes, as: UTF8.self) == magic else { return nil }

        func u32(_ o: Int) -> UInt32 {
            d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
        }
        func u64(_ o: Int) -> UInt64 {
            d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
        }

        let w = Int(u32(8)), h = Int(u32(12)), s = Int(u32(16))
        // Guard before anyone allocates or indexes based on these.
        guard w > 0, h > 0, w <= 100_000, h <= 100_000, s >= w * 4 else { return nil }
        let nameBytes = d.subdata(in: 48..<112).prefix(while: { $0 != 0 })
        return FrameHeader(width: w, height: h, stride: s,
                           format: u32(20), seq: u64(24), tickMs: u64(32),
                           canvasId: u64(40),
                           name: String(decoding: nameBytes, as: UTF8.self))
    }

    var pixelByteCount: Int { stride * height }
}

enum EncoderCore {

    /// H.264 requires even dimensions. Rounding DOWN loses at most one row or
    /// column; rounding up would need invented pixels.
    static func evenSize(_ w: Int, _ h: Int) -> (width: Int, height: Int) {
        (w - (w % 2), h - (h % 2))
    }

    /// Should a new output segment start before writing this frame?
    ///
    /// Two reasons, and they are not the same kind of reason:
    ///
    /// * The frame size changed. AVAssetWriter fixes its dimensions at start,
    ///   so this is a hard requirement — a canvas resized mid-session must roll.
    ///   Squashing instead is what produced a 1000x700 drawing rendered as
    ///   198x878 when ffmpeg was doing this job.
    /// * The segment is long enough. Soft, but an AVAssetWriter file that never
    ///   gets finishWriting() is unplayable, so a crash costs the whole file.
    ///   Rolling periodically bounds that loss to one segment.
    static func shouldRoll(current: (width: Int, height: Int)?,
                           next: (width: Int, height: Int),
                           framesInSegment: Int,
                           maxFramesPerSegment: Int) -> Bool {
        guard let current else { return true }               // nothing open yet
        if current.width != next.width || current.height != next.height { return true }
        if maxFramesPerSegment > 0 && framesInSegment >= maxFramesPerSegment { return true }
        return false
    }

    /// Indices to keep so the finished video lasts at most `maxSeconds`.
    ///
    /// Frames are captured per STROKE, not per second, so a long session yields
    /// however many frames it yields. Raising fps speeds everything up but gives
    /// no control over final length; picking evenly spaced frames does. Returns
    /// every index when the video already fits, so the common case is lossless.
    static func resampleIndices(frameCount: Int, fps: Int, maxSeconds: Double) -> [Int] {
        guard frameCount > 0, fps > 0 else { return [] }
        guard maxSeconds > 0 else { return Array(0..<frameCount) }
        let target = Int(maxSeconds * Double(fps))
        guard target > 0, frameCount > target else { return Array(0..<frameCount) }
        let step = Double(frameCount) / Double(target)
        return (0..<target).map { min(frameCount - 1, Int(($0.double * step).rounded())) }
    }

    /// Inclusive 1-based range, clamped. Out-of-order or out-of-range values are
    /// clamped rather than rejected: this drives a UI slider, where nonsense
    /// input should produce something sane, not an error dialog.
    static func clampRange(from: Int, to: Int, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let lo = max(1, min(from, count)) - 1
        let hi = to <= 0 ? count : max(1, min(to, count))
        return lo < hi ? lo..<hi : lo..<(lo + 1)
    }

    /// Segment file name. Sorts chronologically as text, which is what the
    /// concatenation step and any file browser both want.
    static func segmentName(index: Int, startedAt: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return String(format: "sai-timelapse-%@-%03d.mp4", f.string(from: startedAt), index)
    }
}

private extension Int {
    var double: Double { Double(self) }
}


// --- recognising another watcher on the same frames folder -------------------
//
// Pure halves of WatchGuard.swift, here so they are unit-tested: given what the
// kernel reports about another process, is it a `--watch` encoder reading OUR
// frames folder? A wrong "yes" stops somebody else's process, so every rule
// below errs towards "no".
extension EncoderCore {
    /// Where the DLL writes frames when nobody says otherwise. main.swift's
    /// --frames default and the watcher recognition both read this, because a
    /// watcher started without --frames is still watching this folder.
    static let defaultFramesDir = "~/SAI2-pressure/drive_c/sai-timelapse/frames"

    /// The name the app ships the encoder under. Two copies of the app (an
    /// installed one and a dist/ build) both call it this.
    static let executableName = "sai-timelapse-encoder"

    /// Split a KERN_PROCARGS2 buffer into the executable path and the argument
    /// list. Layout: a 32-bit argc, the executable path, NUL padding, then argc
    /// NUL-terminated arguments (argv[0] first). The environment follows and is
    /// ignored. Nil for anything malformed, never a guess.
    static func parseProcArgs(_ buf: [UInt8]) -> (exe: String, argv: [String])? {
        guard buf.count >= 4 else { return nil }
        let argc = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16 | Int(buf[3]) << 24
        guard argc > 0, argc < 4096 else { return nil }
        var i = 4
        func cString() -> String? {
            guard let end = buf[i...].firstIndex(of: 0) else { return nil }
            defer { i = end + 1 }
            return String(decoding: buf[i..<end], as: UTF8.self)
        }
        guard let exe = cString(), !exe.isEmpty else { return nil }
        while i < buf.count, buf[i] == 0 { i += 1 }
        var argv: [String] = []
        while argv.count < argc {
            guard i < buf.count, let s = cString() else { return nil }
            argv.append(s)
        }
        return (exe, argv)
    }

    /// The frames folder `argv` watches, or nil when it is not a --watch run.
    ///
    /// Mirrors the argument loop in main.swift, including which options take a
    /// value: skipping those is what keeps a path that happens to contain
    /// "--watch" from being read as the flag. --finalize, --rebuild and --probe
    /// all take precedence over --watch there, so a run with any of them is not
    /// a watcher here either.
    static func watchedFolder(argv: [String]) -> String? {
        let takesValue: Set<String> = ["--frames", "--out", "--fps", "--max-seconds", "--from",
                                       "--to", "--segment-frames", "--rebuild", "--probe"]
        var frames = defaultFramesDir
        var watch = false, other = false
        var i = 1                                   // argv[0] is the program
        while i < argv.count {
            let a = argv[i]
            if takesValue.contains(a) {
                let v = i + 1 < argv.count ? argv[i + 1] : ""
                if a == "--frames" { frames = v }
                if a == "--rebuild" || a == "--probe" { other = true }
                i += 2; continue
            }
            if a == "--watch" { watch = true }
            if a == "--finalize" || a == "--finalise" { other = true }
            i += 1
        }
        return watch && !other ? frames : nil
    }

    /// One spelling per folder: tilde expanded, `.`/`..` and trailing slashes
    /// gone, symlinks resolved (/tmp is /private/tmp). A relative path cannot be
    /// resolved for ANOTHER process without its working directory, so it gets
    /// no spelling at all and never matches anything.
    ///
    /// realpath(3), not URL.resolvingSymlinksInPath(): that one strips a leading
    /// /private on purpose, so it turns /private/tmp back into /tmp. A folder
    /// that does not exist cannot be resolved and keeps its tidied spelling.
    static func canonicalFolder(_ path: String) -> String? {
        let p = NSString(string: path).expandingTildeInPath
        guard p.hasPrefix("/") else { return nil }
        let tidy = (p as NSString).standardizingPath
        guard let r = realpath(tidy, nil) else { return tidy }
        defer { free(r) }
        return String(cString: r)
    }

    /// Is the program at `exe` an encoder? By file name: the shipped name, or
    /// whatever this copy is called (the tests build it under another name).
    static func isEncoder(exe: String, ownName: String) -> Bool {
        let name = (exe as NSString).lastPathComponent
        return name == executableName || name == ownName
    }
}

extension EncoderCore {
    /// The number for a live writer's next segment: one past the highest
    /// "<prefix>.NNN.mp4" already in `existing` (a directory listing), or 0 when
    /// there is none. Never a number that is already on disk, because creating
    /// a segment deletes whatever is at its path (see LiveWriter.append).
    ///
    /// Only names that are EXACTLY the prefix, a dot, digits and ".mp4" count:
    /// another canvas whose name merely starts the same ("Sketch 2", "Sketch.v2")
    /// has segments of its own, and the finished "<prefix>.mp4" is not one.
    static func nextSegmentIndex(prefix: String, existing: [String]) -> Int {
        let head = prefix + "."
        var next = 0
        for n in existing where n.hasPrefix(head) && n.hasSuffix(".mp4") {
            let digits = n.dropFirst(head.count).dropLast(4)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let i = Int(digits) else { continue }
            next = max(next, i + 1)
        }
        return next
    }

    /// Turn a canvas name into something safe for a filename. Empty or
    /// all-punctuation names fall back to the id so two canvases can never
    /// collide on disk.
    static func outputName(base: URL, canvasName: String, canvasId: UInt64,
                           multipleCanvases: Bool) -> URL {
        guard multipleCanvases else { return base }
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = canvasName.components(separatedBy: bad).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = cleaned.isEmpty ? String(format: "canvas-%llx", canvasId) : cleaned
        let ext = base.pathExtension.isEmpty ? "mp4" : base.pathExtension
        return base.deletingPathExtension()
            .appendingPathExtension("\(label).\(ext)")
    }
}

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


extension EncoderCore {
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

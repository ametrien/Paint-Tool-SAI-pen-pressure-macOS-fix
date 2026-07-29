// main.swift — sai-timelapse-encoder
//
// Turns the raw .frame files the DLL dumps into H.264 video, using AVFoundation.
// Replaces the ffmpeg scaffolding in tools/make-timelapse.sh: no dependency to
// install, and it can consume frames while recording is still running.
//
// Pure logic lives in EncoderCore.swift and is unit-tested; this file is the
// AVFoundation and filesystem glue.
//
//   sai-timelapse-encoder [options]
//     --frames <dir>      default ~/SAI2-pressure/drive_c/sai-timelapse/frames
//     --out <file>        default ~/Movies/sai-timelapse.mp4
//     --fps <n>           playback speed (default 12). Frames are captured per
//                         STROKE, so this is the speed control.
//     --max-seconds <s>   cap the finished length by dropping evenly spaced
//                         frames. Better than fps for "make it 30 seconds".
//     --from <n> --to <n> inclusive 1-based frame range
//     --segment-frames <n> roll a new file every n frames (default 0 = never)
//     --keep              do not delete frames after encoding
//     --watch             keep running, encoding frames as they appear
//
// SEPARATE PROCESS from the pressure helper, deliberately: the helper's job is
// realtime pen input, and an encoder doing GPU work and disk I/O in the same
// process invites jitter on exactly the path this project exists to protect.

import AVFoundation
import Foundation

// --- arguments -------------------------------------------------------------

func home(_ p: String) -> String { NSString(string: p).expandingTildeInPath }

var framesDir = home("~/SAI2-pressure/drive_c/sai-timelapse/frames")
var outPath = home("~/Movies/sai-timelapse.mp4")
var fps = 12
var maxSeconds = 0.0
var rangeFrom = 1, rangeTo = 0
var segmentFrames = 0
var keepFrames = false
var watch = false
var finalizeOnly = false
var rebuildDir = ""
var probePath = ""

var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    func next() -> String { args.isEmpty ? "" : args.removeFirst() }
    switch a {
    case "--frames": framesDir = home(next())
    case "--out": outPath = home(next())
    case "--fps": fps = max(1, Int(next()) ?? 12)
    case "--max-seconds": maxSeconds = Double(next()) ?? 0
    case "--from": rangeFrom = Int(next()) ?? 1
    case "--to": rangeTo = Int(next()) ?? 0
    case "--segment-frames": segmentFrames = Int(next()) ?? 0
    case "--keep": keepFrames = true
    case "--watch": watch = true
    case "--finalize", "--finalise": finalizeOnly = true
    case "--rebuild": rebuildDir = home(next())
    case "--probe": probePath = home(next())
    case "-h", "--help":
        print("""
        sai-timelapse-encoder — build a video from captured SAI frames

          --frames <dir>       where the DLL writes .frame files
          --out <file>         output video
          --fps <n>            playback speed (default 12)
          --max-seconds <s>    cap length by dropping evenly spaced frames
          --from <n> --to <n>  inclusive 1-based frame range
          --segment-frames <n> roll a new file every n frames
          --keep               keep frames after encoding
          --watch              encode continuously as frames appear
          --finalize           stitch --watch segments into one video per canvas
          --rebuild <dir>      concatenate a drawing's session pieces in <dir>
                               into --out, without re-encoding them
          --probe <file>       print a video's dimensions and length
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown option: \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

// --- one output segment ----------------------------------------------------

/// Wraps an AVAssetWriter for a single output file. A segment has ONE size for
/// its whole life: AVAssetWriter fixes dimensions when it starts, so a frame of
/// a different size needs a new segment (see EncoderCore.shouldRoll).
final class Segment {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let width: Int, height: Int
    let url: URL
    private(set) var frameCount = 0

    init?(url: URL, width: Int, height: Int, fps: Int) {
        self.url = url; self.width = width; self.height = height
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        writer = w
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        // Not a live feed: let AVFoundation apply backpressure rather than
        // pretending frames arrive in real time.
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
    }

    /// Frames carry no usable wall-clock timing — they are captured per stroke —
    /// so presentation times are synthetic and evenly spaced. That IS the
    /// timelapse compression: one captured frame becomes one played frame.
    func append(bgra: Data, stride: Int, fps: Int) -> Bool {
        guard let pool = adaptor.pixelBufferPool else { return false }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
              let buf = pb else { return false }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let dst = CVPixelBufferGetBaseAddress(buf) else { return false }
        let dstStride = CVPixelBufferGetBytesPerRow(buf)
        let rowBytes = width * 4

        // Copy row by row: the source stride is the canvas width, the
        // destination stride is whatever CoreVideo chose (often padded), and
        // height may be one row shorter after the even-size rounding.
        bgra.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            for y in 0..<height {
                memcpy(dst.advanced(by: y * dstStride),
                       base.advanced(by: y * stride),
                       rowBytes)
            }
        }

        while !input.isReadyForMoreMediaData { usleep(2000) }
        let ok = adaptor.append(buf, withPresentationTime:
                                    CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps)))
        if ok { frameCount += 1 }
        return ok
    }

    func finish() {
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }
}

// --- encoding pass ---------------------------------------------------------

func frameFiles(in dir: String) -> [URL] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    return names.filter { $0.hasSuffix(".frame") }.sorted()
        .map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
}

/// Split frames by canvas before encoding, so several open documents become
/// several videos rather than one interleaved mess. Grouping is by canvas ID
/// (the struct address), never by name — see FrameHeader.canvasId.
func encodeAll(_ files: [URL]) -> Int {
    var groups: [UInt64: [URL]] = [:]
    var labels: [UInt64: String] = [:]
    for f in files {
        guard let fh = FileHandle(forReadingAtPath: f.path),
              let head = try? fh.read(upToCount: FrameHeader.byteCount),
              let hdr = FrameHeader.parse(head) else { continue }
        try? fh.close()
        groups[hdr.canvasId, default: []].append(f)
        labels[hdr.canvasId] = hdr.name        // last seen wins, so renames relabel
    }
    guard !groups.isEmpty else { return 0 }
    if groups.count > 1 {
        print("\(groups.count) canvases recorded — one video each")
    }
    let base = URL(fileURLWithPath: outPath)
    var total = 0
    for (id, group) in groups.sorted(by: { $0.key < $1.key }) {
        let out = EncoderCore.outputName(base: base, canvasName: labels[id] ?? "",
                                         canvasId: id, multipleCanvases: groups.count > 1)
        total += encode(group.sorted { $0.lastPathComponent < $1.lastPathComponent }, to: out)
    }
    return total
}

@discardableResult
func encode(_ files: [URL], to outURL: URL) -> Int {
    guard !files.isEmpty else { return 0 }

    let range = EncoderCore.clampRange(from: rangeFrom, to: rangeTo, count: files.count)
    let ranged = Array(files[range])
    let keep = Set(EncoderCore.resampleIndices(frameCount: ranged.count,
                                               fps: fps, maxSeconds: maxSeconds))
    if keep.count < ranged.count {
        print("resampling \(ranged.count) frames down to \(keep.count) for a \(Int(maxSeconds))s video")
    }

    let base = outURL
    var segment: Segment?
    var segmentIndex = 0
    var written = 0
    var consumed: [URL] = []
    let started = Date()

    for (i, f) in ranged.enumerated() {
        guard keep.contains(i) else { consumed.append(f); continue }
        guard let data = try? Data(contentsOf: f),
              let hdr = FrameHeader.parse(data),
              data.count >= FrameHeader.byteCount + hdr.pixelByteCount else {
            // A frame still being written, or a truncated leftover. Skip it and
            // leave it alone — on the next pass it will be complete.
            continue
        }
        let px = data.subdata(in: FrameHeader.byteCount..<(FrameHeader.byteCount + hdr.pixelByteCount))
        let (ew, eh) = EncoderCore.evenSize(hdr.width, hdr.height)

        if EncoderCore.shouldRoll(current: segment.map { ($0.width, $0.height) },
                                  next: (ew, eh),
                                  framesInSegment: segment?.frameCount ?? 0,
                                  maxFramesPerSegment: segmentFrames) {
            segment?.finish()
            if segment != nil { segmentIndex += 1 }
            let url = segmentIndex == 0 ? base
                : base.deletingPathExtension()
                      .appendingPathExtension("\(segmentIndex).mp4")
            guard let s = Segment(url: url, width: ew, height: eh, fps: fps) else {
                FileHandle.standardError.write("could not start writing \(url.path)\n".data(using: .utf8)!)
                return written
            }
            segment = s
            if segmentIndex > 0 { print("size changed — new segment \(url.lastPathComponent)") }
        }

        if segment?.append(bgra: px, stride: hdr.stride, fps: fps) == true {
            written += 1
            consumed.append(f)
        }
    }
    segment?.finish()

    if !keepFrames {
        for f in consumed { try? FileManager.default.removeItem(at: f) }
    }
    if written > 0 {
        let secs = Double(written) / Double(fps)
        print(String(format: "wrote %@  (%d frames at %dfps = %.1fs, %.1fs elapsed)",
                     outURL.path, written, fps, secs, Date().timeIntervalSince(started)))
    }
    return written
}

// --- live encoding ---------------------------------------------------------

/// One canvas being encoded AS IT IS DRAWN, rather than after the fact.
///
/// The point is disk. Raw frames are ~3 MB each, so a session that is not
/// encoded until you ask for it accumulates gigabytes; encoding as frames
/// arrive keeps only the handful not yet consumed. That is how art-timelapse
/// has always worked, and it is the better trade — the video becomes the
/// storage, instead of being built from storage.
///
/// The writer stays OPEN across polls, which is the whole difference from the
/// original --watch: that opened a fresh writer each pass, and since a new
/// AVAssetWriter truncates its output file, every poll silently threw away
/// everything encoded before it.
final class LiveWriter {
    private let base: URL
    private let label: String
    private let fps: Int
    private let maxFramesPerSegment: Int
    private var segment: Segment?
    private var index = 0
    private(set) var total = 0

    /// What the canvas looked like when this session started and how it looks
    /// now. Together they are how a LATER session recognises this drawing —
    /// see LibraryCore. Captured here because this is the only place the raw
    /// pixels pass through: once a frame is inside an H.264 segment, getting it
    /// back means decoding video.
    private(set) var opening: CanvasSignature?
    private(set) var closing: CanvasSignature?
    private(set) var startedAt = Date()
    /// The canvas name as SAI reported it, kept verbatim for the library. The
    /// `label` is the filename-safe version and is not interchangeable with it.
    var title = ""

    /// Frames already inside earlier segments of this same session, from a
    /// previous run of the encoder over the same output base.
    private var priorFrames = 0

    init(base: URL, label: String, fps: Int, maxFramesPerSegment: Int) {
        self.base = base; self.label = label; self.fps = fps
        self.maxFramesPerSegment = maxFramesPerSegment

        // Adopt a sidecar this session already left behind. --finalize runs as a
        // separate process and encodes whatever frames arrived after --watch
        // stopped; without this it would overwrite the session's real opening
        // fingerprint with one taken from its last few strokes, and the drawing
        // would stop being recognisable as a continuation of itself.
        let stem = base.deletingPathExtension().lastPathComponent
        let name = label.isEmpty ? stem : "\(stem).\(label)"
        let side = base.deletingLastPathComponent().appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: side),
           let prev = try? sidecarDecoder.decode(SessionSidecar.self, from: data) {
            opening = prev.opening
            closing = prev.closing
            startedAt = prev.startedAt
            title = prev.title
            priorFrames = prev.frames
        }
    }

    /// Segments are separate FILES, not one growing file, because an
    /// AVAssetWriter that never gets finishWriting() produces something no
    /// player will open. Rolling periodically bounds a crash to one segment
    /// instead of the whole session.
    private func url(for i: Int) -> URL {
        let stem = base.deletingPathExtension().lastPathComponent
        let name = label.isEmpty ? stem : "\(stem).\(label)"
        return base.deletingLastPathComponent()
            .appendingPathComponent(String(format: "%@.%03d.mp4", name, i))
    }

    func append(_ px: Data, stride: Int, width: Int, height: Int) -> Bool {
        if EncoderCore.shouldRoll(current: segment.map { ($0.width, $0.height) },
                                  next: (width, height),
                                  framesInSegment: segment?.frameCount ?? 0,
                                  maxFramesPerSegment: maxFramesPerSegment) {
            if segment != nil { segment?.finish(); index += 1 }
            guard let s = Segment(url: url(for: index), width: width, height: height, fps: fps)
            else { return false }
            segment = s
            print("segment \(url(for: index).lastPathComponent)")
        }
        guard segment?.append(bgra: px, stride: stride, fps: fps) == true else { return false }
        total += 1
        if let fp = CanvasSignature.fingerprint(bgra: px, width: width, height: height,
                                                stride: stride) {
            if opening == nil { opening = fp }
            closing = fp
            // Written as we go, not only at the end: --watch is killed by
            // SIGTERM in normal use and outright crashes in abnormal use, and a
            // piece whose fingerprints never reached disk can never be
            // recognised as part of a drawing again.
            writeSidecar()
        }
        return true
    }

    /// The session's metadata, beside its segments, for whoever finalises them —
    /// usually a DIFFERENT process, since --watch and --finalize are separate
    /// runs. Named after the same prefix as the segments so the two are found
    /// together.
    func writeSidecar() {
        guard let opening, let closing else { return }
        let stem = base.deletingPathExtension().lastPathComponent
        let name = label.isEmpty ? stem : "\(stem).\(label)"
        let url = base.deletingLastPathComponent().appendingPathComponent("\(name).json")
        let side = SessionSidecar(title: title, startedAt: startedAt, frames: priorFrames + total,
                                  width: closing.width, height: closing.height,
                                  opening: opening, closing: closing)
        guard let data = try? sidecarEncoder.encode(side) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func finish() {
        segment?.finish(); segment = nil
        writeSidecar()
    }
}

/// What one recording session was, beside the video of it.
struct SessionSidecar: Codable {
    var title: String
    var startedAt: Date
    var frames: Int
    var width: Int
    var height: Int
    var opening: CanvasSignature
    var closing: CanvasSignature
}

let sidecarEncoder: JSONEncoder = {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
}()
let sidecarDecoder: JSONDecoder = {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
}()

var liveWriters: [UInt64: LiveWriter] = [:]
var signalSources: [DispatchSourceSignal] = []

/// Consume whatever frames are present, appending them to the open writers and
/// deleting each one only once it is safely inside a video.
func liveConsume(_ files: [URL]) {
    for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard let data = try? Data(contentsOf: f),
              let hdr = FrameHeader.parse(data),
              data.count >= FrameHeader.byteCount + hdr.pixelByteCount else {
            // Still being written, or truncated. Leave it: the next pass will
            // find it complete. Deleting here would lose a real frame.
            continue
        }
        let px = data.subdata(in: FrameHeader.byteCount..<(FrameHeader.byteCount + hdr.pixelByteCount))
        let (ew, eh) = EncoderCore.evenSize(hdr.width, hdr.height)

        let w = liveWriters[hdr.canvasId] ?? {
            let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            let clean = hdr.name.components(separatedBy: bad).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = clean.isEmpty ? String(format: "canvas-%llx", hdr.canvasId) : clean
            let nw = LiveWriter(base: URL(fileURLWithPath: outPath), label: label,
                                fps: fps, maxFramesPerSegment: segmentFrames > 0 ? segmentFrames : 500)
            nw.title = hdr.name
            liveWriters[hdr.canvasId] = nw
            return nw
        }()
        // Last seen wins, exactly as the batch path does: renaming a canvas
        // mid-session relabels the finished piece rather than splitting it.
        if !hdr.name.isEmpty { w.title = hdr.name }

        if w.append(px, stride: hdr.stride, width: ew, height: eh), !keepFrames {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

func finishLive() {
    for (_, w) in liveWriters { w.finish() }
    let n = liveWriters.values.reduce(0) { $0 + $1.total }
    if n > 0 { print("finished \(liveWriters.count) canvas(es), \(n) frame(s)") }
    liveWriters.removeAll()
}

// --- finalising live segments ----------------------------------------------

/// Stitch the segments produced by --watch into one video per canvas.
///
/// NOTE ON THE DEPRECATION WARNINGS this function produces. `asset.duration`,
/// `tracks(withMediaType:)`, `exportAsynchronously` and `status` are all
/// deprecated in favour of async replacements — which require macOS 13 or 15.
/// This app deploys to macOS 12, so the replacements are not available to it.
/// The warnings are the price of that, and "fixing" them would quietly drop
/// support for older Macs, which is the opposite of what this project is for.
///
/// Live encoding leaves a numbered segment file every 500 frames, because an
/// AVAssetWriter that never gets finishWriting() is unplayable and rolling
/// bounds a crash to one segment. Those are an implementation detail; what
/// somebody wants at the end is one video.
///
/// Concatenation happens through AVMutableComposition, so the encoded frames
/// are reused rather than decoded and re-encoded. Length is applied with
/// scaleTimeRange — asking for 30 seconds re-times the whole thing instead of
/// dropping frames, which is what you want once the frames are already video.
func finalizeSegments() -> Int {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: outPath)
    let dir = base.deletingLastPathComponent()
    let stem = base.deletingPathExtension().lastPathComponent
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }

    // Anything ending .NNN.mp4 is an unfinished segment. Group by everything
    // before the number, so segments left by an EARLIER session are finished
    // too rather than stranded — restricting this to the current base name
    // meant an app update in the middle of a recording lost it.
    _ = stem
    var groups: [String: [(Int, URL)]] = [:]
    for n in names where n.hasSuffix(".mp4") {
        let parts = n.dropLast(4).split(separator: ".")
        guard parts.count >= 2, let idx = Int(parts[parts.count - 1]) else { continue }
        let prefix = parts[0...(parts.count - 2)].joined(separator: ".")
        groups[prefix, default: []].append((idx, dir.appendingPathComponent(n)))
    }
    guard !groups.isEmpty else { return 0 }

    var made = 0
    for (label, segs) in groups.sorted(by: { $0.key < $1.key }) {
        let ordered = segs.sorted { $0.0 < $1.0 }.map { $0.1 }
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid)
        else { continue }

        var at = CMTime.zero
        for seg in ordered {
            let asset = AVURLAsset(url: seg)
            guard let src = asset.tracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            try? track.insertTimeRange(range, of: src, at: at)
            at = CMTimeAdd(at, asset.duration)
        }
        guard at.seconds > 0 else { continue }

        // Re-time to the requested length rather than dropping frames: the
        // frames are already encoded, so speeding them up is both cheaper and
        // smoother than throwing some away.
        if maxSeconds > 0, at.seconds > maxSeconds {
            track.scaleTimeRange(CMTimeRange(start: .zero, duration: at),
                                 toDuration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        }

        let outURL = dir.appendingPathComponent("\(label).mp4")
        try? fm.removeItem(at: outURL)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)
        else { continue }
        ex.outputURL = outURL
        ex.outputFileType = .mp4
        let sem = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { sem.signal() }
        sem.wait()

        if ex.status == .completed {
            for seg in ordered { try? fm.removeItem(at: seg) }
            print(String(format: "wrote %@  (%.1fs)", outURL.path,
                         maxSeconds > 0 ? min(maxSeconds, at.seconds) : at.seconds))
            made += 1
        } else {
            FileHandle.standardError.write(
                "could not finalise \(outURL.lastPathComponent): \(ex.error?.localizedDescription ?? "unknown")\n"
                    .data(using: .utf8)!)
        }
    }
    return made
}

// --- rebuilding a drawing from its pieces ----------------------------------

/// Concatenate a drawing's session pieces into the one video somebody actually
/// wants to watch.
///
/// THE ARCHITECTURE THIS SERVES: pieces are the append-only archive — one file
/// per session, never rewritten — and this output is DERIVED. Delete it and it
/// comes back; a failed rebuild costs nothing, because nothing that holds work
/// was touched. The alternative, extending one growing video each session,
/// rewrites the file holding every previous evening every time somebody draws.
///
/// Passthrough matters as much as safety: it copies the H.264 samples instead of
/// decoding and re-encoding them, so a drawing rebuilt for the tenth time is
/// bit-for-bit as good as the first, and the rebuild runs at disk speed. Only a
/// canvas RESIZED between sessions forces the slow path, because passthrough
/// cannot mix dimensions.
func rebuildDrawing(from piecesDir: String, to outURL: URL, maxSeconds: Double) -> Bool {
    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: piecesDir)) ?? [])
        .filter { $0.hasSuffix(".mp4") && !$0.hasPrefix(".") }
        .sorted()          // piece names are dates, so this is capture order
    guard !names.isEmpty else { return false }

    let comp = AVMutableComposition()
    guard let track = comp.addMutableTrack(withMediaType: .video,
                                           preferredTrackID: kCMPersistentTrackID_Invalid)
    else { return false }

    var at = CMTime.zero
    var sizes: [(CMTime, CGSize, CGAffineTransform)] = []
    for n in names {
        let asset = AVURLAsset(url: URL(fileURLWithPath: piecesDir).appendingPathComponent(n))
        guard let src = asset.tracks(withMediaType: .video).first else { continue }
        let dur = asset.duration
        guard dur.seconds > 0 else { continue }
        try? track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: at)
        sizes.append((at, src.naturalSize, src.preferredTransform))
        at = CMTimeAdd(at, dur)
    }
    guard at.seconds > 0, let first = sizes.first else { return false }

    let uniform = sizes.allSatisfy { $0.1 == first.1 }
    var videoComposition: AVMutableVideoComposition?

    if !uniform {
        // A canvas resized between sessions. Every piece is rendered into one
        // frame big enough for all of them and scaled to fit inside it —
        // deliberately NOT stretched to fill. Squashing a 1000x700 drawing into
        // another aspect ratio is the exact defect this project already fixed
        // once, when ffmpeg was doing this job.
        let renderW = ceil(sizes.map { $0.1.width }.max()! / 2) * 2
        let renderH = ceil(sizes.map { $0.1.height }.max()! / 2) * 2
        let vc = AVMutableVideoComposition()
        vc.renderSize = CGSize(width: renderW, height: renderH)
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (i, (start, size, _)) in sizes.enumerated() {
            let end = i + 1 < sizes.count ? sizes[i + 1].0 : at
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = CMTimeRange(start: start, end: end)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            let scale = min(renderW / size.width, renderH / size.height)
            let tx = (renderW - size.width * scale) / 2
            let ty = (renderH - size.height * scale) / 2
            layer.setTransform(CGAffineTransform(scaleX: scale, y: scale)
                                .concatenating(CGAffineTransform(translationX: tx, y: ty)),
                               at: start)
            inst.layerInstructions = [layer]
            instructions.append(inst)
        }
        vc.instructions = instructions
        videoComposition = vc
    }

    // Length is a RENDITION, not a state: the rebuilt video keeps every frame at
    // full length, and a cap is only applied when somebody asks for one. Baking
    // it in here would re-time already re-timed material every session.
    if maxSeconds > 0, at.seconds > maxSeconds {
        track.scaleTimeRange(CMTimeRange(start: .zero, duration: at),
                             toDuration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
    }

    let preset = (uniform && maxSeconds <= 0)
        ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
    guard let ex = AVAssetExportSession(asset: comp, presetName: preset) else { return false }
    let tmp = outURL.deletingLastPathComponent()
        .appendingPathComponent(".\(outURL.lastPathComponent).building.mp4")
    try? fm.removeItem(at: tmp)
    ex.outputURL = tmp
    ex.outputFileType = .mp4
    ex.videoComposition = videoComposition
    let sem = DispatchSemaphore(value: 0)
    ex.exportAsynchronously { sem.signal() }
    sem.wait()

    guard ex.status == .completed else {
        try? fm.removeItem(at: tmp)
        FileHandle.standardError.write(
            "rebuild failed: \(ex.error?.localizedDescription ?? "unknown")\n".data(using: .utf8)!)
        return false
    }
    // Swap in only once the new file is complete. A rebuild interrupted halfway
    // must leave the previous video playable rather than truncated.
    _ = try? fm.replaceItemAt(outURL, withItemAt: tmp)
    if fm.fileExists(atPath: tmp.path) {          // replaceItemAt declined
        try? fm.removeItem(at: outURL)
        try? fm.moveItem(at: tmp, to: outURL)
    }
    print(String(format: "rebuilt %@  (%d piece(s), %.1fs%@)", outURL.path, names.count,
                 maxSeconds > 0 ? min(maxSeconds, at.seconds) : at.seconds,
                 uniform ? "" : ", mixed sizes"))
    return true
}

// --- run -------------------------------------------------------------------

try? FileManager.default.createDirectory(atPath: (outPath as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)

if !probePath.isEmpty {
    // Diagnostics, and what the tests assert dimensions with — "it produced a
    // file" is not the same claim as "it produced a video of the right shape",
    // and the difference is where the old squashing bug lived.
    let asset = AVURLAsset(url: URL(fileURLWithPath: probePath))
    guard let t = asset.tracks(withMediaType: .video).first else {
        FileHandle.standardError.write("no video track in \(probePath)\n".data(using: .utf8)!)
        exit(1)
    }
    let s = t.naturalSize.applying(t.preferredTransform)
    print(String(format: "%dx%d %.2fs", Int(abs(s.width)), Int(abs(s.height)),
                 asset.duration.seconds))
    exit(0)
}

if !rebuildDir.isEmpty {
    exit(rebuildDrawing(from: rebuildDir, to: URL(fileURLWithPath: outPath),
                        maxSeconds: maxSeconds) ? 0 : 1)
}

if finalizeOnly {
    // Anything captured after the watcher stopped is still raw on disk, so
    // encode it before stitching — otherwise the last few strokes vanish.
    let leftover = frameFiles(in: framesDir)
    if !leftover.isEmpty { liveConsume(leftover); finishLive() }
    let n = finalizeSegments()
    if n == 0 {
        FileHandle.standardError.write("nothing to finalise in \(framesDir)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

if watch {
    print("watching \(framesDir) — Ctrl-C to stop")
    // A half-written video is unplayable, so the writers MUST be closed on the
    // way out. signal() alone is not enough: only async-signal-safe calls are
    // legal in a handler, and finishing an AVAssetWriter is nowhere near that.
    // DispatchSource delivers it as an ordinary event instead.
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { finishLive(); exit(0) }
        src.resume()
        signalSources.append(src)
    }
    // Deliberately simple polling. The frames directory changes at drawing
    // speed, a few times a second at most, so an FSEvents stream would be
    // machinery for no gain.
    DispatchQueue.global().async {
        while true {
            let files = frameFiles(in: framesDir)
            if !files.isEmpty { liveConsume(files) }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
    dispatchMain()
} else {
    let files = frameFiles(in: framesDir)
    if files.isEmpty {
        FileHandle.standardError.write("no .frame files in \(framesDir)\n".data(using: .utf8)!)
        exit(1)
    }
    print("found \(files.count) frame(s)")
    if encodeAll(files) == 0 {
        FileHandle.standardError.write("nothing encoded\n".data(using: .utf8)!)
        exit(1)
    }
}

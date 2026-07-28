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
        guard let fh = try? FileHandle(forReadingAtPath: f.path),
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

// --- run -------------------------------------------------------------------

try? FileManager.default.createDirectory(atPath: (outPath as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)

if watch {
    print("watching \(framesDir) — Ctrl-C to stop")
    // Deliberately simple polling. The frames directory changes at drawing
    // speed, a few times a second at most, so an FSEvents stream would be
    // machinery for no gain.
    while true {
        let files = frameFiles(in: framesDir)
        if !files.isEmpty { _ = encodeAll(files) }
        Thread.sleep(forTimeInterval: 1.0)
    }
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

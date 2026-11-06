// EncoderTests.swift — unit tests for EncoderCore.swift.
//
// No AVFoundation, no frame files, no SAI. Frame headers are synthesised in
// memory, so the parser and every sizing/segmenting decision are exercised
// without recording anything.
//
// Run:  bash tests/run-tests.sh

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (EncoderTests.swift:\(line))"); failures += 1 }
}

/// Build a header exactly as the DLL writes it, so the test fails if either
/// side's layout drifts.
func makeHeader(width: Int, height: Int, stride: Int? = nil,
                magic: String = "SAITLF2", seq: UInt64 = 1,
                canvasId: UInt64 = 0x8516000, name: String = "NewCanvas1") -> Data {
    var d = Data()
    var m = Array(magic.utf8); while m.count < 8 { m.append(0) }
    d.append(contentsOf: m.prefix(8))
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func put64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    put32(UInt32(width)); put32(UInt32(height))
    put32(UInt32(stride ?? width * 4)); put32(0)
    put64(seq); put64(123_456)
    put64(canvasId)
    var nm = Array(name.utf8); while nm.count < 64 { nm.append(0) }
    d.append(contentsOf: nm.prefix(64))
    return d
}

@main
struct EncoderTests {
    static func main() {

print("EncoderCore tests:")

// --- header parsing --------------------------------------------------------
do {
    let h = FrameHeader.parse(makeHeader(width: 1000, height: 700))
    expect(h != nil, "header: valid header parses")
    expect(h?.width == 1000 && h?.height == 700, "header: dimensions")
    expect(h?.stride == 4000, "header: stride")
    expect(h?.pixelByteCount == 4000 * 700, "header: pixel byte count")
    expect(h?.seq == 1, "header: sequence number")
    expect(h?.canvasId == 0x8516000, "header: canvas id is the struct address")
    expect(h?.name == "NewCanvas1", "header: canvas name")
    expect(FrameHeader.parse(makeHeader(width: 10, height: 10, magic: "SAITLF1")) == nil,
           "header: the older v1 magic is rejected")

    expect(FrameHeader.parse(makeHeader(width: 10, height: 10, magic: "NOPE")) == nil,
           "header: wrong magic rejected")
    expect(FrameHeader.parse(Data(repeating: 0, count: 12)) == nil,
           "header: truncated data rejected")
    // A partially flushed file is normal while recording is live, so this must
    // return nil rather than trap.
    expect(FrameHeader.parse(makeHeader(width: 100, height: 100).prefix(30)) == nil,
           "header: short read rejected, not a crash")

    // THE TRAP: a stride smaller than width*4 would make the row loop read past
    // the end of every row. Remove the `s >= w * 4` guard and this goes green
    // while the encoder walks off the buffer.
    expect(FrameHeader.parse(makeHeader(width: 1000, height: 700, stride: 100)) == nil,
           "header: stride smaller than a row is rejected")
    expect(FrameHeader.parse(makeHeader(width: 0, height: 700)) == nil,
           "header: zero width rejected")
    expect(FrameHeader.parse(makeHeader(width: 999_999, height: 10)) == nil,
           "header: absurd width rejected")
}

// --- even sizing -----------------------------------------------------------
do {
    expect(EncoderCore.evenSize(1000, 700) == (1000, 700), "even: already even is unchanged")
    expect(EncoderCore.evenSize(1237, 569) == (1236, 568), "even: odd dimensions round down")
    expect(EncoderCore.evenSize(7777, 33) == (7776, 32), "even: extreme aspect still even")
}

// --- segment rolling -------------------------------------------------------
do {
    expect(EncoderCore.shouldRoll(current: nil, next: (100, 100),
                                  framesInSegment: 0, maxFramesPerSegment: 500),
           "roll: first frame always opens a segment")
    expect(!EncoderCore.shouldRoll(current: (100, 100), next: (100, 100),
                                   framesInSegment: 10, maxFramesPerSegment: 500),
           "roll: same size mid-segment does not roll")

    // THE TRAP: this is the ffmpeg bug that produced a 1000x700 drawing as
    // 198x878. AVAssetWriter fixes dimensions at start, so a size change MUST
    // roll. Delete the size comparison and this goes green while frames get
    // silently deformed.
    expect(EncoderCore.shouldRoll(current: (1000, 700), next: (199, 878),
                                  framesInSegment: 1, maxFramesPerSegment: 500),
           "roll: a size change forces a new segment")

    expect(EncoderCore.shouldRoll(current: (100, 100), next: (100, 100),
                                  framesInSegment: 500, maxFramesPerSegment: 500),
           "roll: segment length cap rolls")
    expect(!EncoderCore.shouldRoll(current: (100, 100), next: (100, 100),
                                   framesInSegment: 9999, maxFramesPerSegment: 0),
           "roll: cap of zero disables length-based rolling")
}

// --- resampling ------------------------------------------------------------
do {
    expect(EncoderCore.resampleIndices(frameCount: 100, fps: 10, maxSeconds: 0)
           == Array(0..<100), "resample: no limit keeps every frame")
    expect(EncoderCore.resampleIndices(frameCount: 50, fps: 10, maxSeconds: 30)
           == Array(0..<50), "resample: already short enough is untouched")

    let r = EncoderCore.resampleIndices(frameCount: 1000, fps: 10, maxSeconds: 5)
    expect(r.count == 50, "resample: 1000 frames to 5s at 10fps gives 50")
    expect(r.first == 0, "resample: starts at the first frame")
    expect(r.last! < 1000, "resample: never indexes past the end")
    expect(zip(r, r.dropFirst()).allSatisfy { $0 <= $1 }, "resample: indices are monotonic")

    expect(EncoderCore.resampleIndices(frameCount: 0, fps: 10, maxSeconds: 5).isEmpty,
           "resample: no frames gives no indices")
    expect(EncoderCore.resampleIndices(frameCount: 10, fps: 0, maxSeconds: 5).isEmpty,
           "resample: zero fps gives no indices")
}

// --- per-canvas output naming ----------------------------------------------
do {
    let base = URL(fileURLWithPath: "/tmp/SAI Timelapse.mp4")
    expect(EncoderCore.outputName(base: base, canvasName: "Sketch", canvasId: 1,
                                  multipleCanvases: false) == base,
           "naming: a single canvas keeps the plain output name")
    expect(EncoderCore.outputName(base: base, canvasName: "Sketch", canvasId: 1,
                                  multipleCanvases: true).lastPathComponent
           == "SAI Timelapse.Sketch.mp4",
           "naming: several canvases get the canvas name appended")
    // A name is a LABEL, never identity. Two canvases sharing a name must still
    // land in different files, which the id fallback guarantees for empty names
    // and the caller guarantees by grouping on id.
    expect(EncoderCore.outputName(base: base, canvasName: "", canvasId: 0x8516000,
                                  multipleCanvases: true).lastPathComponent
           == "SAI Timelapse.canvas-8516000.mp4",
           "naming: an empty name falls back to the canvas id")
    expect(!EncoderCore.outputName(base: base, canvasName: "a/b:c*d", canvasId: 1,
                                   multipleCanvases: true).lastPathComponent.contains("/"),
           "naming: path separators are stripped from canvas names")
}

// --- range clamping --------------------------------------------------------
do {
    expect(EncoderCore.clampRange(from: 1, to: 0, count: 50) == 0..<50,
           "range: 'to 0' means to the end")
    expect(EncoderCore.clampRange(from: 10, to: 20, count: 50) == 9..<20,
           "range: 1-based input becomes 0-based half-open")
    expect(EncoderCore.clampRange(from: -5, to: 999, count: 50) == 0..<50,
           "range: out-of-range values clamp instead of failing")
    expect(EncoderCore.clampRange(from: 30, to: 10, count: 50).count == 1,
           "range: reversed range degrades to a single frame")
    expect(EncoderCore.clampRange(from: 1, to: 10, count: 0).isEmpty,
           "range: no frames gives an empty range")
}

// --- recognising another watcher on the frames folder ------------------------
// A wrong "yes" here makes a new watcher SIGTERM somebody else's process, so the
// "no" cases matter as much as the "yes" ones. The whole path, with real
// processes, is tested in run-tests.sh.
do {
    /// A KERN_PROCARGS2 buffer laid out as the kernel lays it out: argc, the
    /// executable path, NUL padding, argv, then the environment.
    func procArgs(exe: String, argv: [String], env: [String] = ["HOME=/Users/x"],
                  padding: Int = 3, argc: Int? = nil) -> [UInt8] {
        var b: [UInt8] = []
        withUnsafeBytes(of: Int32(argc ?? argv.count).littleEndian) { b.append(contentsOf: $0) }
        b += Array(exe.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for s in argv + env { b += Array(s.utf8) + [0] }
        return b
    }
    let app = "/Applications/SAI Pen Pressure.app/Contents/Resources/sai-timelapse-encoder"
    let frames = "/Users/x/SAI2-pressure/drive_c/sai-timelapse/frames"
    // Exactly the command line the app builds in startLiveEncoder(), spaces and all.
    let shipped = [app, "--frames", frames,
                   "--out", "/Users/x/Movies/SAI Timelapses/.recording/session 2026-11-06 1716.mp4",
                   "--fps", "12", "--watch"]

    let parsed = EncoderCore.parseProcArgs(procArgs(exe: app, argv: shipped))
    expect(parsed?.exe == app, "procargs: the executable path, spaces included")
    expect(parsed?.argv == shipped, "procargs: every argument, and not the environment")
    expect(EncoderCore.parseProcArgs(procArgs(exe: app, argv: shipped, padding: 0))?.argv == shipped,
           "procargs: no padding after the executable is fine too")
    expect(EncoderCore.parseProcArgs([1, 0]) == nil, "procargs: a truncated buffer is refused")
    expect(EncoderCore.parseProcArgs(procArgs(exe: app, argv: ["a"], env: [], argc: 5)) == nil,
           "procargs: fewer arguments than argc claims is refused, not padded out")
    var cut = procArgs(exe: app, argv: shipped, env: [])
    cut.removeLast()                                   // last argument loses its NUL
    expect(EncoderCore.parseProcArgs(cut) == nil, "procargs: an unterminated argument is refused")

    expect(EncoderCore.watchedFolder(argv: shipped) == frames,
           "watcher: the app's own --watch command line watches --frames")
    expect(EncoderCore.watchedFolder(argv: [app, "--watch"]) == EncoderCore.defaultFramesDir,
           "watcher: without --frames it watches the default folder, as main.swift does")
    expect(EncoderCore.watchedFolder(argv: [app, "--frames", frames, "--out", "/x.mp4"]) == nil,
           "watcher: a one-shot encode is not a watcher")
    expect(EncoderCore.watchedFolder(argv: [app, "--frames", frames, "--out", "/x.mp4",
                                            "--fps", "12", "--finalize"]) == nil,
           "watcher: the app's --finalize run is not a watcher")
    expect(EncoderCore.watchedFolder(argv: [app, "--frames", frames, "--watch", "--finalize"]) == nil,
           "watcher: --finalize wins over --watch, as it does in main.swift")
    expect(EncoderCore.watchedFolder(argv: [app, "--probe", "/x.mp4", "--watch"]) == nil,
           "watcher: --probe wins over --watch")
    expect(EncoderCore.watchedFolder(argv: [app, "--frames", frames, "--out", "/v/--watch"]) == nil,
           "watcher: '--watch' inside a VALUE is not the flag")
    expect(EncoderCore.watchedFolder(argv: [app, "--out", "--watch", "--frames", frames]) == nil,
           "watcher: an option's value is skipped even when it looks like a flag")
    expect(EncoderCore.watchedFolder(argv: [app, "--frames", "/a", "--frames", frames, "--watch"]) == frames,
           "watcher: the last --frames wins, as it does in main.swift")
    expect(EncoderCore.watchedFolder(argv: [app]) == nil, "watcher: no arguments, no watcher")

    expect(EncoderCore.canonicalFolder("/a/b/") == EncoderCore.canonicalFolder("/a/b"),
           "folder: a trailing slash is the same folder")
    expect(EncoderCore.canonicalFolder("/a/./c/../b") == EncoderCore.canonicalFolder("/a/b"),
           "folder: . and .. are the same folder")
    expect(EncoderCore.canonicalFolder("/tmp") == "/private/tmp"
           && EncoderCore.canonicalFolder("/private/tmp") == "/private/tmp",
           "folder: symlinks are resolved, both spellings of /tmp are one folder")
    expect(EncoderCore.canonicalFolder("~/f") == NSString(string: "~/f").expandingTildeInPath,
           "folder: ~ is the home folder")
    expect(EncoderCore.canonicalFolder("frames") == nil,
           "folder: a relative path has no spelling, so it matches nothing")
    expect(EncoderCore.canonicalFolder("/a/b") != EncoderCore.canonicalFolder("/a/b2"),
           "folder: a folder is not its neighbour with a longer name")

    expect(EncoderCore.isEncoder(exe: app, ownName: "whatever"),
           "encoder: the shipped name is recognised from any copy")
    expect(EncoderCore.isEncoder(exe: "/w/enc-live", ownName: "enc-live"),
           "encoder: so is this copy's own name")
    expect(!EncoderCore.isEncoder(exe: "/usr/bin/python3", ownName: "enc-live"),
           "encoder: another program with the same arguments is left alone")
    expect(!EncoderCore.isEncoder(exe: "/x/sai-timelapse-encoder-old", ownName: "enc-live"),
           "encoder: a name that only starts the same is not the encoder")
}

// --- numbering live segments -------------------------------------------------
// Creating a segment deletes whatever is at its path, so the next number must
// never be one already on disk. A writer that counted from 0 instead made
// --finalize replace the watcher's whole session with its few leftover frames.
do {
    let p = "session 2026-11-06 1716.Sketch"
    func next(_ names: [String]) -> Int { EncoderCore.nextSegmentIndex(prefix: p, existing: names) }
    expect(next([]) == 0, "segments: the first one in an empty folder is .000")
    expect(next(["\(p).000.mp4"]) == 1,
           "segments: after the watcher's .000, --finalize writes .001 instead of replacing it")
    expect(next(["\(p).000.mp4", "\(p).001.mp4", "\(p).json"]) == 2,
           "segments: one past the highest, and the sidecar is not a segment")
    expect(next(["\(p).000.mp4", "\(p).004.mp4"]) == 5,
           "segments: past the highest even with a gap, so the stitching order holds")
    expect(next(["\(p).999.mp4"]) == 1000 && next(["\(p).1000.mp4"]) == 1001,
           "segments: past .999 the numbers just grow a digit")
    expect(next(["\(p).mp4"]) == 0, "segments: the finished video of the session is not a segment")
    expect(next(["session 2026-11-06 1716.Sketch 2.000.mp4"]) == 0,
           "segments: another canvas whose name starts the same has its own numbers")
    expect(next(["\(p).v2.000.mp4", "\(p).001.000.mp4"]) == 0,
           "segments: so does a canvas whose name continues after a dot")
    expect(next(["session 2026-11-06 1939.Sketch.003.mp4"]) == 0,
           "segments: another session's segments are not this one's")
    expect(next(["\(p).00a.mp4", "\(p)..mp4", "\(p).-1.mp4", "\(p).٣.mp4"]) == 0,
           "segments: anything that is not plain ASCII digits is not a segment number")
}

if failures > 0 {
    print("FAILED: \(failures) test(s)")
    exit(1)
}
print("All EncoderCore tests passed.")
    }
}

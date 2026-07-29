// Settings.swift — everything the app remembers between launches, and where it
// keeps it.
//
// Moved out of main.swift unchanged. Each setting is a small file in Application
// Support rather than UserDefaults: the same values are read by the DLL running
// inside SAI and by shell one-liners during diagnosis, and a file is the only
// format all three can agree on.
//
// SAIPP_CONFIG_DIR redirects the lot, which is what lets the tests run against
// throwaway folders instead of the real settings.

import Foundation

/// Path whose EXISTENCE means recording is switched OFF.
///
/// Inverted on purpose: recording is on by default, so the common case leaves no
/// file behind and a fresh install records without anyone finding a setting.
/// dev mode uses the opposite polarity because its default is the opposite.
func timelapseOffMarker() -> String { appSupport() + "/timelapse-off.txt" }
/// Is timelapse recording switched on?
///
/// A free function reading the flag file directly, because launchSAIApp() is
/// top-level while the toggle lives on the app delegate. The file IS the source
/// of truth (same pattern as devmode.txt), so there is nothing to keep in sync.
func timelapseRecordingEnabled() -> Bool {
    !FileManager.default.fileExists(atPath: timelapseOffMarker())
}
/// Where finished videos are written. Defaults to ~/Movies; the Recording tab
/// can point it anywhere.
func timelapseOutputFolder() -> String {
    if let s = try? String(contentsOfFile: appSupport() + "/timelapse-folder.txt", encoding: .utf8),
       case let t = s.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
       FileManager.default.fileExists(atPath: t) {
        return t
    }
    // Our own folder rather than dumping into ~/Movies alongside everything
    // else. Created on demand so the Choose panel has somewhere to open.
    let d = NSString(string: "~/Movies/SAI Timelapses").expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
/// Index into the export-length popup: 30s, 1m, 2m, everything.
///
/// This used to cap the recording itself. It no longer does: a drawing's video
/// is kept at full length and lossless, and a cap makes a separate copy when you
/// export one. Capping the archive meant re-timing already re-timed material
/// every time a drawing gained another evening.
func storedTimelapseLengthIndex() -> Int {
    guard let s = try? String(contentsOfFile: appSupport() + "/timelapse-length.txt", encoding: .utf8),
          let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), (0...3).contains(i)
    else { return 3 }          // "Everything" — never silently drop someone's work
    return i
}
/// Seconds for the chosen length, or 0 meaning "keep every frame".
func timelapseMaxSeconds() -> Int {
    [30, 60, 120, 0][storedTimelapseLengthIndex()]
}
/// What one canvas has cost on disk so far.
struct TLCanvasUsage { let name: String; let frames: Int; let bytes: Int64 }
/// Frames are raw BGRA, roughly 3 MB each, so the folder grows fast enough that
/// people deserve to see the number rather than discover it. Grouped by canvas
/// id (the struct address) exactly as the encoder groups, so the breakdown here
/// matches the videos that will come out.
func timelapseUsage(_ dir: String) -> (total: Int64, canvases: [TLCanvasUsage]) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return (0, []) }
    var total: Int64 = 0
    var frames: [UInt64: Int] = [:]
    var bytes: [UInt64: Int64] = [:]
    var labels: [UInt64: String] = [:]
    for n in names where n.hasSuffix(".frame") {
        let path = "\(dir)/\(n)"
        let sz = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        total += sz
        // Read only the header, never the pixels: a folder of 2000 frames is
        // gigabytes, and this runs every time the tab refreshes.
        guard let fh = FileHandle(forReadingAtPath: path),
              let head = try? fh.read(upToCount: 112), head.count >= 112 else { continue }
        try? fh.close()
        let id = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self) }
        frames[id, default: 0] += 1
        bytes[id, default: 0] += sz
        if labels[id] == nil {
            let raw = head.subdata(in: 48..<112).prefix(while: { $0 != 0 })
            labels[id] = String(decoding: raw, as: UTF8.self)
        }
    }
    let list = frames.keys.sorted().map {
        TLCanvasUsage(name: labels[$0] ?? String(format: "canvas-%llx", $0),
                      frames: frames[$0] ?? 0, bytes: bytes[$0] ?? 0)
    }
    return (total, list)
}
func prettyBytes(_ b: Int64) -> String {
    let mb = Double(b) / 1_048_576
    return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}
/// Shorten a path for display: the home directory becomes ~.
func prettyPath(_ p: String) -> String {
    let h = NSHomeDirectory()
    return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
}
func appSupport() -> String {
    // where the saved SAI-folder config lives; override with SAIPP_CONFIG_DIR
    // (used to test the first-run wizard without clobbering a real config).
    let d = ProcessInfo.processInfo.environment["SAIPP_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath }
        ?? NSString(string: "~/Library/Application Support/SAIPenPressure").expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
func savedSAIPath() -> String? {
    guard let s = try? String(contentsOfFile: appSupport() + "/config.txt", encoding: .utf8) else { return nil }
    let p = s.trimmingCharacters(in: .whitespacesAndNewlines); return p.isEmpty ? nil : p
}
/// Stored override, if the user set one explicitly. nil = follow the tablet.
func storedMaxPressureOverride() -> Int? {
    guard let s = try? String(contentsOfFile: appSupport() + "/pmax.txt", encoding: .utf8),
          let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          v >= 255, v <= PressureCore.maxPressureCeiling else { return nil }
    return v
}
/// Full scale to run at: an explicit override if set, otherwise whatever the
/// tablet reports, otherwise 1023. Asking the hardware beats guessing — and
/// beats asking the user, who mostly doesn't know and can't verify a wrong answer
/// (setting more levels than the tablet has adds noise, not detail).
/// The last full scale a tablet actually reported, remembered across launches.
/// Separate from `pmax.txt`, which is the USER's explicit override — writing
/// detection results there would silently turn Auto into a permanent pin.
func cachedDetectedFullScale() -> Int? {
    guard let s = try? String(contentsOfFile: appSupport() + "/pmax-detected.txt", encoding: .utf8),
          let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          v >= 255, v <= PressureCore.maxPressureCeiling else { return nil }
    return v
}
func cacheDetectedFullScale(_ v: Int) {
    try? "\(v)".write(toFile: appSupport() + "/pmax-detected.txt", atomically: true, encoding: .utf8)
}
func savedMaxPressure() -> Int {
    let detected = detectTabletFullScale()
    if let d = detected { cacheDetectedFullScale(d) }      // remember for a sleepy next start
    return PressureCore.resolveMaxPressure(override: storedMaxPressureOverride(),
                                           detected: detected,
                                           cached: cachedDetectedFullScale())
}
func saveMaxPressure(_ v: Int) {
    try? "\(v)".write(toFile: appSupport() + "/pmax.txt", atomically: true, encoding: .utf8)
    PressureCore.maxPressure = v
}
/// Mirror the setting into the prefix so the DLL picks it up on next SAI launch.
func writeMaxPressureForDLL() {
    let dir = "\(appPrefix)/drive_c"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? "\(PressureCore.maxPressure)".write(toFile: "\(dir)/wt_pmax.txt", atomically: true, encoding: .ascii)
}
// Pen feel (response curve). Stored as a gamma; 1.0 = untouched.
func savedGamma() -> Double {
    guard let s = try? String(contentsOfFile: appSupport() + "/gamma.txt", encoding: .utf8),
          let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          v >= 0.4, v <= 2.5 else { return 1.0 }
    return v
}
func saveGamma(_ v: Double) {
    try? String(format: "%.2f", v).write(toFile: appSupport() + "/gamma.txt", atomically: true, encoding: .utf8)
    PressureCore.pressureGamma = v
}
func saveSAIPath(_ p: String) { try? p.write(toFile: appSupport() + "/config.txt", atomically: true, encoding: .utf8) }

// SAIProcess.swift — launching SAI, noticing when it is open, waking it up, and
// the timelapse recording that runs alongside it.
//
// Moved out of main.swift unchanged. These belong together because they are all
// about the SAI PROCESS rather than about our own window: the recording lifecycle
// is driven entirely by SAI opening and closing, and the encoder is started and
// stopped from the same handful of moments.
//
// Two rules worth keeping in view while reading:
//   * the live encoder is a SEPARATE process, so a slow video encode can never
//     add jitter to the pen path this project exists to protect;
//   * SIGTERM, never SIGKILL, when stopping it — an AVAssetWriter that never
//     gets finishWriting() leaves a video no player will open.

import AppKit
import Foundation

/// Base name for THIS recording session, timestamped and remembered.
///
/// It has to be stable between the encoder starting and the video being
/// finalised, which is why it is written down rather than generated twice — and
/// it has to differ between sessions, because it did not: every session wrote
/// to "SAI Timelapse.mp4", so making a second video, or simply drawing again
/// tomorrow, silently overwrote the finished timelapse from before.
/// Recording happens in a STAGING folder, not in the videos folder itself:
/// segments and sidecars are working files, and a finished session only moves
/// into a drawing's folder once it has been recognised as belonging there.
/// Hidden, because nobody browsing their timelapses wants to see the plumbing.
func timelapseStagingFolder() -> String {
    let d = timelapseOutputFolder() + "/.recording"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
func timelapseSessionBase() -> String {
    let marker = appSupport() + "/timelapse-session.txt"
    if let s = try? String(contentsOfFile: marker, encoding: .utf8) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only if it points into staging. A marker left by an older version
        // names a path in the VIDEOS folder, and honouring it made the new build
        // scatter segments and fingerprint sidecars in among somebody's finished
        // videos — visible in the wild before this check existed.
        if !t.isEmpty, t.hasPrefix(timelapseStagingFolder() + "/") { return t }
    }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
    let base = "\(timelapseStagingFolder())/session \(f.string(from: Date())).mp4"
    try? base.write(toFile: marker, atomically: true, encoding: .utf8)
    return base
}
/// The library index, INSIDE the videos folder.
///
/// It started beside the settings, on the reasoning that it is bookkeeping and
/// the videos should stand on their own without it. That was wrong in a way that
/// only showed when somebody moved their videos folder: one global index went on
/// describing drawings that lived somewhere else entirely, so the new folder
/// showed rows with no videos behind them. An index describes one folder, so it
/// belongs to that folder — and a folder carried to another Mac now arrives
/// knowing which sessions belong together.
func timelapseLibraryPath() -> String { timelapseOutputFolder() + "/.library.json" }
func makeLibraryStore() -> LibraryStore {
    let path = timelapseLibraryPath()
    // One-time move for anyone who recorded with the build that kept it in
    // Application Support.
    let old = appSupport() + "/library.json"
    let fm = FileManager.default
    if fm.fileExists(atPath: old), !fm.fileExists(atPath: path) {
        try? fm.moveItem(atPath: old, toPath: path)
    }
    return LibraryStore(videosDir: timelapseOutputFolder(), indexPath: path)
}
/// File whatever sessions have just finished, then rebuild the drawings they
/// landed in. Returns a one-line summary for the log.
///
/// Rebuilding is per drawing and only for the ones that changed: it copies the
/// encoded samples rather than re-encoding, so this stays cheap even for a
/// drawing with thirty evenings in it.
@discardableResult
func fileAndRebuildSessions() -> String {
    guard let res = Bundle.main.resourcePath else { return "" }
    let enc = "\(res)/sai-timelapse-encoder"
    let store = makeLibraryStore()
    let filed = store.fileFinishedSessions()
    guard !filed.isEmpty else { return "" }
    for id in Set(filed.map(\.drawingId)) { store.rebuild(id, encoder: enc) }
    let asks = filed.filter { $0.askAbout != nil }.count
    return "timelapse: filed \(filed.count) session(s)"
        + (asks > 0 ? ", \(asks) to confirm" : "")
}
/// Turn whatever has been recorded into finished videos, now, and wait for it.
///
/// Called when SAI closes, so a session always ends with a video rather than
/// with segments that only become one if somebody thinks to press a button.
/// Losing a drawing session because you quit without pressing Make video is not
/// a reasonable thing to ask of anyone.
///
/// Synchronous on purpose: the caller is usually on its way to exit(0), and a
/// half-written video is one no player will open.
@discardableResult
func finalizeTimelapseNow() -> Bool {
    guard let res = Bundle.main.resourcePath else { return false }
    let enc = "\(res)/sai-timelapse-encoder"
    guard FileManager.default.isExecutableFile(atPath: enc) else { return false }
    let frames = "\(appPrefix)/drive_c/sai-timelapse/frames"
    // Nothing captured? Then there is nothing to finish, and no empty file to
    // leave behind.
    let hasFrames = ((try? FileManager.default.contentsOfDirectory(atPath: frames)) ?? [])
        .contains { $0.hasSuffix(".frame") }
    let outDir = timelapseStagingFolder()
    let hasSegments = ((try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? [])
        .contains { n in
            guard n.hasSuffix(".mp4") else { return false }
            let parts = n.dropLast(4).split(separator: ".")
            return parts.count >= 2 && Int(parts[parts.count - 1]) != nil
        }
    guard hasFrames || hasSegments else { return false }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: enc)
    // No --max-seconds here any more. A session is archived at FULL length and
    // capped only when somebody exports one, because capping the archive would
    // re-time already re-timed material every time a drawing gained an evening.
    p.arguments = ["--frames", frames, "--out", timelapseSessionBase(), "--fps", "12", "--finalize"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { wlog("timelapse: auto-finalise could not start — \(error)"); return false }
    p.waitUntilExit()
    wlog("timelapse: auto-finalised on close (exit \(p.terminationStatus))")
    if p.terminationStatus == 0 {
        let summary = fileAndRebuildSessions()
        if !summary.isEmpty { wlog(summary) }
        endTimelapseSession()
    }
    return p.terminationStatus == 0
}
/// Forget the session, so the next recording starts a new set of files rather
/// than appending to one that has already been turned into a video.
func endTimelapseSession() {
    try? FileManager.default.removeItem(atPath: appSupport() + "/timelapse-session.txt")
}
/// Start encoding in the background for this SAI session. Safe to call when
/// recording is off or the encoder is missing — it simply does nothing.
func startLiveEncoder() {
    guard g_liveEncoder == nil, timelapseRecordingEnabled(),
          let res = Bundle.main.resourcePath else { return }
    let enc = "\(res)/sai-timelapse-encoder"
    guard FileManager.default.isExecutableFile(atPath: enc) else { return }
    let frames = "\(appPrefix)/drive_c/sai-timelapse/frames"
    try? FileManager.default.createDirectory(atPath: frames, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: timelapseOutputFolder(),
                                             withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: enc)
    p.arguments = ["--frames", frames, "--out", timelapseSessionBase(), "--fps", "12", "--watch"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); g_liveEncoder = p; wlog("timelapse: live encoder started") }
    catch { wlog("timelapse: could not start the live encoder — \(error)") }
}
/// Stop it politely. SIGTERM rather than SIGKILL matters: the encoder closes
/// its AVAssetWriters on the way out, and a video that never gets
/// finishWriting() is one no player will open.
func stopLiveEncoder() {
    guard let p = g_liveEncoder, p.isRunning else { g_liveEncoder = nil; return }
    kill(p.processIdentifier, SIGTERM)
    // Give it a moment to close cleanly before letting go.
    for _ in 0..<40 where p.isRunning { usleep(50_000) }
    g_liveEncoder = nil
    wlog("timelapse: live encoder stopped")
}
func isForeignSAIWindow(_ w: [String: Any]) -> Bool {
    let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
    guard owner.contains("wine") || owner.contains("sai") else { return false }
    let pid = pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0)
    return pid != g_myPID
}
// Is any SAI/Wine window still on screen? Used to decide when SAI has really
// closed (see launchSAIApp's terminationHandler).
func saiWindowIsOpen() -> Bool {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list {
        guard isForeignSAIWindow(w) else { continue }
        if (w[kCGWindowLayer as String] as? Int ?? 0) == 0 { return true }
    }
    return false
}
func pollUntilSAICloses() {
    let t = Timer(timeInterval: 2.0, repeats: true) { timer in
        if !saiWindowIsOpen() { timer.invalidate(); exit(0) }
    }
    RunLoop.main.add(t, forMode: .common)
}
// LAUNCH (runs only after the pressure tap is active): start SAI; quit the app
// when SAI closes.
/// Keep the prefix's copy of our DLL in step with the one inside the app bundle.
///
/// installBridge() runs only from performSetup() — first-time setup or an
/// explicit reinstall. So an app UPGRADE used to ship a new wintab32.dll in the
/// bundle while the prefix quietly kept the old one: the user got none of the
/// fix, saw the old bug, and had every reason to conclude the fix didn't work.
/// A DLL-side fix that only reaches people who happen to reinstall is a fix
/// that did not ship.
///
/// Compares bytes rather than timestamps (copying does not preserve mtime
/// reliably, and a same-size build is still a different build). Safe at this
/// point specifically: SAI has not been started yet, so nothing has the file
/// mapped. The registry override is deliberately not touched — it persists in
/// the prefix and rewriting it would mean spawning wine on every launch.
func syncBridgeDLL() {
    guard let res = Bundle.main.resourcePath else { return }   // dev mode: no bundle
    let src = "\(res)/wintab32.dll"
    let dst = "\(appPrefix)/drive_c/windows/system32/wintab32.dll"
    guard let bundled = FileManager.default.contents(atPath: src) else { return }
    if let installed = FileManager.default.contents(atPath: dst), installed == bundled { return }
    try? FileManager.default.createDirectory(
        atPath: "\(appPrefix)/drive_c/windows/system32", withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: dst)
    try? FileManager.default.copyItem(atPath: src, toPath: dst)
}
func launchSAIApp() {
    // One SAI at a time (#28). Two instances share one Wine prefix and contend
    // over the same settings and recovery files, and a second copy is never
    // what "Launch" was meant to do — the window is already there, so raise it
    // rather than starting a rival.
    if saiWindowIsOpen() {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        if let w = list.first(where: { isForeignSAIWindow($0) }),
           let pid = w[kCGWindowOwnerPID as String] as? Int, pid != 0 {
            NSRunningApplication(processIdentifier: pid_t(pid))?
                .activate(options: [.activateAllWindows])
        }
        pollUntilSAICloses()      // still quit with SAI, as a fresh launch would
        return
    }
    syncBridgeDLL()               // an upgraded app must not leave a stale DLL behind
    // Ask the hardware once more before committing the value (issue #27). At
    // app startup a Bluetooth tablet may still be asleep and answer nothing; by
    // the time someone presses Launch it is usually awake. This is the LAST
    // safe moment to change our mind: the DLL reads wt_pmax.txt at load and SAI
    // reads the axis once at WTOpen, so adopting a new value after this point
    // would leave the two halves scaling differently. An explicit user override
    // is never second-guessed.
    if storedMaxPressureOverride() == nil, let live = detectTabletFullScale() {
        cacheDetectedFullScale(live)
        PressureCore.maxPressure = live
    }
    writeMaxPressureForDLL()      // must land before the DLL loads
    applyWineShortcutRemap(g_wine)          // Cmd->Ctrl via Wine (every launch; idempotent)
    let pf = "\(appPrefix)/drive_c/wt_pressure.txt"
    try? "0".write(toFile: pf, atomically: true, encoding: .ascii)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: g_wine); p.arguments = ["sai2.exe"]
    p.currentDirectoryURL = URL(fileURLWithPath: "\(appPrefix)/drive_c/SAI2")
    var e = ProcessInfo.processInfo.environment
    e["WINEPREFIX"] = appPrefix; e["WINEDEBUG"] = "-all"
    // Timelapse recording is read by the DLL at load time, so it can only be
    // decided here — toggling the menu item mid-session has no effect until the
    // next launch, which is why the menu title says so. An explicit
    // WT_TIMELAPSE in the environment always wins, for testing.
    if e["WT_TIMELAPSE"] == nil, timelapseRecordingEnabled() { e["WT_TIMELAPSE"] = "1" }
    p.environment = e
    startLiveEncoder()
    p.terminationHandler = { _ in
        try? "0".write(toFile: pf, atomically: true, encoding: .ascii)
        stopLiveEncoder()
        finalizeTimelapseNow()
        // The process we spawned exiting does NOT always mean SAI closed — Wine
        // can hand off to another process and let this one exit immediately,
        // which used to make us quit while SAI was still on screen. Only exit
        // once no SAI window is left.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !saiWindowIsOpen() { exit(0) }
            else { pollUntilSAICloses() }
        }
    }
    try? p.run()                                            // async; quits the app when SAI closes
}

// RecordingActions.swift — the Recording tab's buttons and the menu items that
// mirror them: make the video now, discard the recording, show the folder.
//
// Moved out of main.swift unchanged, and kept beside RecordingUI.swift rather
// than inside it so the tab's layout and the tab's behaviour can each be read
// without scrolling past the other.

import AppKit
import Foundation

extension SetupController {

    @objc func toggleTimelapse(_ sender: NSMenuItem) { timelapseOn.toggle() }
    func timelapseFrameCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: timelapseFramesDir))?
            .filter { $0.hasSuffix(".frame") }.count ?? 0
    }
    /// Build a video from whatever has been captured. Runs the encoder that
    /// ships in Resources — signed with the app, so no separate Gatekeeper
    /// approval — off the main thread, since a long session takes a moment.
    /// Build the finished video.
    ///
    /// Most of the work has already happened: the encoder has been turning
    /// frames into segments while you drew. This stops it, stitches the
    /// segments into one video per canvas, and applies the chosen length.
    /// Anything captured after the encoder stopped is encoded first, so the
    /// last few strokes are not lost.
    @objc func makeTimelapseVideo() {
        let frames = timelapseFrameCount()
        let segments = timelapseSegmentCount()
        guard frames > 0 || segments > 0 else {
            alertUser("Nothing recorded yet.\n\nTurn on “Record timelapse”, then launch SAI and draw. "
                      + "Each finished stroke captures a frame.")
            return
        }
        guard let enc = Bundle.main.resourcePath.map({ "\($0)/sai-timelapse-encoder" }),
              FileManager.default.isExecutableFile(atPath: enc) else {
            alertUser("The timelapse encoder is missing from the app bundle.")
            return
        }
        stopLiveEncoder()          // it holds the segments open

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: enc)
            // Full length: the cap belongs to an export, not to the archive.
            p.arguments = ["--frames", self.timelapseFramesDir,
                           "--out", timelapseSessionBase(), "--fps", "12", "--finalize"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try? p.run()
            let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            wlog("timelapse: finalize exited \(p.terminationStatus)\n\(log)")

            // File the finished session into its drawing and rebuild that
            // drawing's video. What somebody wants to see afterwards is the
            // whole drawing so far, not tonight's fragment of it.
            let store = makeLibraryStore()
            let filed = store.fileFinishedSessions()
            for id in Set(filed.map(\.drawingId)) { store.rebuild(id, encoder: enc) }
            let made = filed.compactMap { store.lib.drawing(id: $0.drawingId) }
                .map { store.videoURL($0).path }

            DispatchQueue.main.async {
                // Recording continues if SAI is still open. Stopping the
                // encoder to finalise is a means, not an intention — leaving it
                // stopped meant one video per SAI session and no way back
                // except quitting SAI, which is not what "Make video" implies.
                if p.terminationStatus == 0 { endTimelapseSession() }
                if saiWindowIsOpen() { startLiveEncoder() }

                if p.terminationStatus == 0, let first = made.first {
                    self.showPreview(first)
                    if made.count > 1 {
                        alertUser("Made \(made.count) videos — one per canvas.\n\nIn \(prettyPath(timelapseOutputFolder()))")
                    }
                    NSWorkspace.shared.activateFileViewerSelecting(made.map { URL(fileURLWithPath: $0) })
                    self.askAboutPendingSessions()
                } else {
                    alertUser("Could not build the video.\n\n\(log)")
                }
                self.refreshRecordingTab()
            }
        }
    }
    /// Segments already encoded and waiting to be stitched. In the staging
    /// folder, never among the finished videos — a drawing's folder holds only
    /// things worth watching.
    func timelapseSegmentCount() -> Int {
        let dir = timelapseStagingFolder()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
        // <stem>[.label].NNN.mp4 — a trailing number is what marks a segment.
        // Anything ending .NNN.mp4 is an unfinished segment, whichever session
        // wrote it. Keying this to the current session name meant a recording
        // from before an app update became invisible — still on disk, but with
        // no way to turn it into a video.
        return names.filter { n in
            guard n.hasSuffix(".mp4") else { return false }
            let parts = n.dropLast(4).split(separator: ".")
            return parts.count >= 2 && Int(parts[parts.count - 1]) != nil
        }.count
    }
    @objc func revealTimelapseVideos() {
        let dir = timelapseOutputFolder()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
    }
    /// Still reachable from the menu when recording is on but nothing has been
    /// captured — "where would frames even go?" is a fair question at that point.
    @objc func revealTimelapseFrames() {
        try? FileManager.default.createDirectory(atPath: timelapseFramesDir,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: timelapseFramesDir)])
    }
    @objc func discardTimelapseFrames() {
        let n = timelapseFrameCount()
        let segs = timelapseSegmentCount()
        guard n > 0 || segs > 0 else { alertUser("Nothing recorded to discard."); return }
        // Segments ARE the recording once the live encoder has been through, so
        // discarding only loose frames would leave the session behind.
        stopLiveEncoder()
        let a = NSAlert()
        a.messageText = segs > 0 ? "Discard this recording?"
                                 : "Discard \(n) recorded frame(s)?"
        a.informativeText = "This only deletes the timelapse recording. Your artwork is untouched."
        a.addButton(withTitle: "Discard"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: timelapseFramesDir)) ?? []
        where f.hasSuffix(".frame") {
            try? FileManager.default.removeItem(atPath: "\(timelapseFramesDir)/\(f)")
        }
        // Everything in staging: segments, and the fingerprint sidecars beside
        // them. Finished drawings live elsewhere and are not part of
        // "discard the recording" — this button throws away tonight, never the
        // work of previous evenings.
        let outDir = timelapseStagingFolder()
        for f in (try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? [] {
            try? FileManager.default.removeItem(atPath: "\(outDir)/\(f)")
        }
        endTimelapseSession()
        rebuildMenus()
        if saiWindowIsOpen() { startLiveEncoder() }
        refreshRecordingTab()
    }
}

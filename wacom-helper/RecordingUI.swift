// RecordingUI.swift — the Recording tab: whether a timelapse is being captured
// right now, what it has cost so far, and the buttons that end a session early.
//
// Moved out of main.swift unchanged. Kept apart from LibraryUI.swift on purpose,
// because the two tabs answer different questions: this one is about what is
// happening while you draw, and that one is about what has accumulated. The
// status line here is the most important text in the window, and it should not
// have to compete with a scrolling list for room.

import AppKit
import AVKit
import Foundation

extension SetupController {

    /// The Recording tab. Everything about the timelapse lives here so the Setup
    /// tab stays about getting SAI running.
    func buildRecordingTab() {
        recordingTab = NSStackView()
        recordingTab.orientation = .vertical
        recordingTab.alignment = .leading
        recordingTab.spacing = 10
        recordingTab.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        recordingTab.addArrangedSubview(lbl("Recording", 18, bold: true))
        recordingTab.addArrangedSubview(
            lbl("What gets captured while you draw. Finished videos are in the Videos tab.\n"
                + "Captures the canvas itself, not the screen — no panels, no zooming, no cursor.",
                12, color: .secondaryLabelColor))

        recCheck = NSButton(checkboxWithTitle: "Record a timelapse while I draw",
                            target: self, action: #selector(recToggle))
        recordingTab.addArrangedSubview(recCheck)
        recordingTab.addArrangedSubview(
            lbl("Takes effect the next time SAI launches.", 11, color: .tertiaryLabelColor))

        recFramesLabel = lbl("", 12)
        recordingTab.addArrangedSubview(recFramesLabel)
        recUsageLabel = lbl("", 11, color: .secondaryLabelColor)
        recUsageLabel.usesSingleLineMode = false
        recUsageLabel.lineBreakMode = .byWordWrapping
        recUsageLabel.maximumNumberOfLines = 8
        recordingTab.addArrangedSubview(recUsageLabel)

        let folderRow = NSStackView(); folderRow.orientation = .horizontal
        folderRow.alignment = .centerY; folderRow.spacing = 8
        folderRow.addArrangedSubview(lbl("Save to", 12, bold: true))
        recFolderLabel = lbl(prettyPath(timelapseOutputFolder()), 11, color: .secondaryLabelColor)
        recFolderLabel.lineBreakMode = .byTruncatingMiddle
        folderRow.addArrangedSubview(recFolderLabel)
        let chooseBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseTimelapseFolder))
        chooseBtn.bezelStyle = .rounded; chooseBtn.controlSize = .small
        folderRow.addArrangedSubview(chooseBtn)
        recordingTab.addArrangedSubview(folderRow)

        let btnRow = NSStackView(); btnRow.orientation = .horizontal; btnRow.spacing = 8
        recMakeBtn = NSButton(title: "Make video…", target: self, action: #selector(makeTimelapseVideo))
        recMakeBtn.bezelStyle = .rounded
        recMakeBtn.keyEquivalent = "\r"
        recDiscardBtn = NSButton(title: "Discard recording", target: self,
                                 action: #selector(discardTimelapseFrames))
        recDiscardBtn.bezelStyle = .rounded
        // "Show frames" used to matter when frames sat on disk until you asked
        // for a video. They are now encoded and deleted within a second of
        // being captured, so that button opened an empty folder — the finished
        // videos are the thing anyone actually wants to get to.
        let showBtn = NSButton(title: "Show videos", target: self, action: #selector(revealTimelapseVideos))
        showBtn.bezelStyle = .rounded
        btnRow.addArrangedSubview(recMakeBtn)
        btnRow.addArrangedSubview(recDiscardBtn)
        btnRow.addArrangedSubview(showBtn)
        recordingTab.addArrangedSubview(btnRow)

        // Preview. Watching the result is how you find out the length or speed
        // is wrong, and sending people to Finder to check made that a chore.
        // The preview is remembered across launches, which is useful right
        // after making a video and confusing a week later when it shows
        // something unrelated to what is on screen now. So it can be dismissed.
        let previewRow = NSStackView(); previewRow.orientation = .horizontal
        previewRow.alignment = .centerY; previewRow.spacing = 8
        recPreviewLabel = lbl("", 11, color: .secondaryLabelColor)
        previewRow.addArrangedSubview(recPreviewLabel)
        recHidePreviewBtn = NSButton(title: "Hide preview", target: self,
                                     action: #selector(hidePreview))
        recHidePreviewBtn.bezelStyle = .rounded; recHidePreviewBtn.controlSize = .small
        recHidePreviewBtn.isHidden = true
        previewRow.addArrangedSubview(recHidePreviewBtn)
        recordingTab.addArrangedSubview(previewRow)
        recPreview = AVPlayerView()
        recPreview.translatesAutoresizingMaskIntoConstraints = false
        recPreview.controlsStyle = .inline
        recPreview.videoGravity = .resizeAspect
        recPreview.heightAnchor.constraint(equalToConstant: 220).isActive = true
        recPreview.widthAnchor.constraint(equalToConstant: CGFloat(rowWidth)).isActive = true
        recPreview.isHidden = true
        recordingTab.addArrangedSubview(recPreview)

        recordingTab.addArrangedSubview(
            lbl("Closing SAI makes the video by itself — this button is only for making one early.",
                11, color: .tertiaryLabelColor))
        recordingTab.addArrangedSubview(
            lbl("You can make a video while SAI is still open — recording carries on afterwards.",
                11, color: .tertiaryLabelColor))
        recordingTab.addArrangedSubview(
            lbl("Drawing on this again another day adds to the same video — see the Videos tab.",
                11, color: .tertiaryLabelColor))
        recordingTab.addArrangedSubview(
            lbl("Undo is captured at your next stroke rather than the moment you press it.",
                11, color: .tertiaryLabelColor))
        refreshRecordingTab()
        restorePreview()
    }
    func refreshRecordingTab() {
        guard recCheck != nil else { return }
        recCheck.state = timelapseOn ? .on : .off
        // Frames are encoded away within a second of being captured, so the
        // raw count is near zero while recording. What has been captured lives
        // in the segments, and counting only frames made a working recording
        // look like nothing at all.
        let n = timelapseFrameCount()
        let segs = timelapseSegmentCount()
        recFramesLabel.stringValue = (n == 0 && segs == 0)
            ? (timelapseOn ? "Nothing recorded yet — launch SAI and draw."
                           : "Recording is off.")
            : (segs > 0
               ? "Recorded and encoded\(n > 0 ? ", \(n) frame\(n == 1 ? "" : "s") still to process" : ".")"
               : "\(n) frame\(n == 1 ? "" : "s") recorded.")
        recMakeBtn.isEnabled = n > 0 || segs > 0
        recDiscardBtn.isEnabled = n > 0 || segs > 0
        let use = timelapseUsage(timelapseFramesDir)
        if use.total == 0 {
            recUsageLabel.stringValue = ""
        } else {
            var lines = ["Using \(prettyBytes(use.total)) on disk"
                         + (use.canvases.count > 1 ? " across \(use.canvases.count) canvases:" : ":")]
            for c in use.canvases.prefix(6) {
                lines.append("   \(c.name.isEmpty ? "(unnamed)" : c.name) — "
                             + "\(c.frames) frame\(c.frames == 1 ? "" : "s"), \(prettyBytes(c.bytes))")
            }
            if use.canvases.count > 6 { lines.append("   …and \(use.canvases.count - 6) more") }
            lines.append("Frames are deleted as they are encoded. Beyond ~2 GB the oldest detail is "
                         + "thinned (every 2nd frame) rather than losing the start.")
            recUsageLabel.stringValue = lines.joined(separator: "\n")
        }
        recFolderLabel?.stringValue = prettyPath(timelapseOutputFolder())
    }
    /// Show a finished video in the Recording tab. The path is remembered so
    /// the preview survives a relaunch — otherwise the tab looks empty right
    /// after the app restarts, as though nothing had ever been made.
    func showPreview(_ path: String) {
        guard recPreview != nil else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            recPreview.isHidden = true; recPreviewLabel.stringValue = ""; return
        }
        try? path.write(toFile: appSupport() + "/timelapse-last.txt",
                        atomically: true, encoding: .utf8)
        recPreview.player = AVPlayer(url: URL(fileURLWithPath: path))
        recPreview.isHidden = false
        recHidePreviewBtn?.isHidden = false
        recPreviewLabel.stringValue = "Last video: \(prettyPath(path))"
        applyLayout()
    }
    /// Dismiss the preview and forget the video, so it does not reappear on the
    /// next launch. The file itself is untouched.
    @objc func hidePreview() {
        recPreview?.player?.pause()
        recPreview?.player = nil
        recPreview?.isHidden = true
        recHidePreviewBtn?.isHidden = true
        recPreviewLabel?.stringValue = ""
        try? FileManager.default.removeItem(atPath: appSupport() + "/timelapse-last.txt")
        applyLayout()
    }
    func restorePreview() {
        guard let p = try? String(contentsOfFile: appSupport() + "/timelapse-last.txt",
                                  encoding: .utf8) else { return }
        showPreview(p.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @objc func recToggle() { timelapseOn = (recCheck.state == .on); refreshRecordingTab() }
    @objc func recLengthChanged() {
        try? String(recLengthPopup.indexOfSelectedItem)
            .write(toFile: appSupport() + "/timelapse-length.txt", atomically: true, encoding: .utf8)
    }
    @objc func chooseTimelapseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.directoryURL = URL(fileURLWithPath: timelapseOutputFolder())
        guard p.runModal() == .OK, let url = p.url else { return }
        setTimelapseFolder(url.path)
    }
    /// Point recording at another folder, and show what is in it.
    ///
    /// Separate from the panel so it can be tested, and because refreshing the
    /// Recording tab alone left the Videos tab showing the previous folder's
    /// contents — with a cached store still pointing at the old index.
    func setTimelapseFolder(_ path: String) {
        try? path.write(toFile: appSupport() + "/timelapse-folder.txt",
                        atomically: true, encoding: .utf8)
        libStore = nil
        refreshRecordingTab()
        refreshLibraryTab()
    }
}

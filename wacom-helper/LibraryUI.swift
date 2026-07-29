// LibraryUI.swift — the Timelapses tab, and the question the library asks.
//
// A drawing made over several evenings is several session pieces plus one
// combined video, and none of that is visible from the Recording tab, which is
// about what is happening RIGHT NOW. This is the other half: what has
// accumulated, and the ability to correct how it was grouped.
//
// The regrouping controls are not a luxury. LibraryCore is allowed to guess at
// identity only because a wrong guess is one click from being fixed here; if
// this tab did not exist, "we can always sort it out afterwards" would mean
// dragging mp4s between hidden folders in Finder. See LibraryCore's header.

import AppKit
import AVFoundation
import AVKit
import Foundation

/// The export lengths offered, in one place: the tab's default popup and the
/// export dialog have to agree, and they drifted apart when they each had their
/// own list.
enum LibraryExport {
    static let choiceTitles = ["30 seconds", "1 minute", "2 minutes", "Full length"]
    static func seconds(at index: Int) -> Int {
        [30, 60, 120, 0][max(0, min(index, 3))]
    }
}


/// A poster frame that plays the video when the pointer is over it.
///
/// A timelapse is motion; a still frame of one is the least informative thing
/// about it, and the last frame of two drawings can look very alike. Hovering to
/// see it move is how you tell them apart without opening anything.
///
/// The player is built on entry and torn down on exit rather than kept around:
/// a folder with thirty drawings in it would otherwise hold thirty decoders open
/// for a list nobody is looking at.
final class HoverVideoView: NSView {
    private let url: URL
    private let poster = NSImageView()
    private var player: AVPlayer?
    private var layerView: NSView?
    private var endObserver: Any?
    /// Exposed so the wiring can be tested without synthesising mouse events —
    /// tracking areas are AppKit's job, but "hovering starts the video" is ours.
    private(set) var isPreviewing = false

    init(url: URL, image: NSImage?) {
        self.url = url
        super.init(frame: .zero)
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.image = image
        poster.translatesAutoresizingMaskIntoConstraints = false
        addSubview(poster)
        NSLayoutConstraint.activate([
            poster.topAnchor.constraint(equalTo: topAnchor),
            poster.bottomAnchor.constraint(equalTo: bottomAnchor),
            poster.leadingAnchor.constraint(equalTo: leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        // .activeInKeyWindow, so a background window does not start playing
        // video because the pointer happens to be over it.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { beginPreview() }
    override func mouseExited(with event: NSEvent) { endPreview() }

    func beginPreview() {
        guard !isPreviewing, FileManager.default.fileExists(atPath: url.path) else { return }
        let p = AVPlayer(url: url)
        p.isMuted = true                       // there is no audio, and never will be
        let host = NSView()
        host.wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = false
        let pl = AVPlayerLayer(player: p)
        pl.videoGravity = .resizeAspect
        pl.frame = bounds
        pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.layer?.addSublayer(pl)
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Loop: a timelapse of one evening can be two seconds long, and a
        // preview that plays once and freezes looks like it has crashed.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak p] _ in
                p?.seek(to: .zero); p?.play()
            }
        player = p
        layerView = host
        isPreviewing = true
        p.play()
    }

    func endPreview() {
        guard isPreviewing else { return }
        player?.pause()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        layerView?.removeFromSuperview()
        layerView = nil
        player = nil
        isPreviewing = false
    }

    deinit {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
    }
}

extension SetupController {

    // MARK: - the tab

    func buildLibraryTab() -> NSStackView {
        let tab = NSStackView()
        tab.orientation = .vertical
        tab.alignment = .leading
        tab.spacing = 10
        tab.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        tab.addArrangedSubview(lbl("Your videos", 18, bold: true))
        tab.addArrangedSubview(
            lbl("One video per drawing. Come back to a drawing later and it is added "
                + "to the same video.\nHover over a still to play it.",
                11, color: .secondaryLabelColor))

        libStack = NSStackView()
        libStack.orientation = .vertical
        libStack.alignment = .leading
        libStack.spacing = 12
        // A stack view used as a documentView must be laid out by constraints.
        // Left on autoresizing translation it keeps its zero frame, and every
        // row inside it is present, unhidden, and drawn at (0,0,0,0) — the tab
        // renders as a blank rectangle. This is the same trap the tab bar in
        // main.swift documents, in the opposite direction.
        libStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = libStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            libStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            libStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            // Width pinned, bottom deliberately NOT: that is what makes the
            // content scroll vertically instead of squashing to fit.
            libStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // A fixed height, not a minimum: with a minimum the list grew to fill
        // the tab and pushed the controls below it off the bottom.
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        tab.addArrangedSubview(scroll)

        // The export default lives here rather than with the recording
        // settings: nothing about recording is capped any more, and a control
        // sitting next to the thing it governs needs less explaining.
        let lenRow = NSStackView(); lenRow.orientation = .horizontal
        lenRow.alignment = .centerY; lenRow.spacing = 8
        lenRow.addArrangedSubview(lbl("Export length", 12, bold: true))
        recLengthPopup = NSPopUpButton()
        recLengthPopup.addItems(withTitles: LibraryExport.choiceTitles)
        recLengthPopup.selectItem(at: storedTimelapseLengthIndex())
        recLengthPopup.target = self; recLengthPopup.action = #selector(recLengthChanged)
        lenRow.addArrangedSubview(recLengthPopup)
        lenRow.addArrangedSubview(
            lbl("your drawings always keep a full-length video", 11, color: .tertiaryLabelColor))
        tab.addArrangedSubview(lenRow)

        libFooter = lbl("", 11, color: .secondaryLabelColor)
        tab.addArrangedSubview(libFooter)
        libraryTab = tab
        refreshLibraryTab()
        return tab
    }

    /// Rebuild the list from the index on disk. Cheap enough to call on every
    /// tab switch, which keeps it honest: the index is the truth, and this view
    /// never holds state of its own.
    func refreshLibraryTab() {
        guard libStack != nil else { return }
        let store = makeLibraryStore()
        libStore = store
        for v in libStack.arrangedSubviews { v.removeFromSuperview() }

        let drawings = store.lib.drawings.sorted {
            ($0.lastDrawn ?? .distantPast) > ($1.lastDrawn ?? .distantPast)
        }
        for d in drawings { libStack.addArrangedSubview(row(for: d, store: store)) }

        // Videos that are simply IN the folder: everything recorded before
        // drawings existed as a concept, and anything a rebuild has not claimed.
        // They are real videos, and a list that ignores them while announcing
        // "nothing recorded yet" is telling somebody their work is gone.
        let loose = looseVideos(in: store.videosDir)
        if !loose.isEmpty {
            if !drawings.isEmpty {
                libStack.addArrangedSubview(
                    lbl("Older recordings", 13, bold: true, color: .secondaryLabelColor))
            }
            libStack.addArrangedSubview(
                lbl("Made before this update, so they are not grouped into drawings. "
                    + "Recordings from now on are.", 11, color: .secondaryLabelColor))
            for url in loose { libStack.addArrangedSubview(looseRow(url)) }
        }

        if drawings.isEmpty && loose.isEmpty {
            libStack.addArrangedSubview(
                lbl("Nothing recorded yet. Draw in SAI with recording on, and your "
                    + "drawings will appear here.", 12, color: .secondaryLabelColor))
            libFooter.stringValue = ""
            return
        }

        let pieces = drawings.reduce(0) { $0 + $1.pieces.count }
        var footer = ""
        if !drawings.isEmpty { footer = "\(drawings.count) drawing(s), \(pieces) session(s)" }
        if !loose.isEmpty {
            footer += (footer.isEmpty ? "" : ", ") + "\(loose.count) older video(s)"
        }
        footer += " — " + prettyBytes(folderSize(store.videosDir))
        if !store.lib.pending.isEmpty {
            footer += "  ·  \(store.lib.pending.count) session(s) to confirm"
        }
        libFooter.stringValue = footer
    }

    /// One drawing: a poster frame, what it is, and what can be done to it.
    private func row(for d: Drawing, store: LibraryStore) -> NSView {
        let box = NSStackView()
        box.orientation = .horizontal
        box.alignment = .top
        box.spacing = 12

        let thumb = HoverVideoView(url: store.videoURL(d), image: poster(for: store.videoURL(d)))
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: 96).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 72).isActive = true
        box.addArrangedSubview(thumb)

        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3

        let title = lbl(d.title.isEmpty ? d.folder : d.title, 13, bold: true)
        col.addArrangedSubview(title)

        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        var facts = "\(d.pieces.count) session(s), \(d.totalFrames) frames"
        if let last = d.lastDrawn { facts += " · last drawn \(f.string(from: last))" }
        col.addArrangedSubview(lbl(facts, 11, color: .secondaryLabelColor))

        // A session waiting on an answer is shown on the drawing itself, not
        // only in a prompt that may have been dismissed.
        if let p = store.lib.pending.first(where: { $0.drawingId == d.id }),
           let other = store.lib.drawing(id: p.candidateId) {
            let ask = lbl("Might continue “\(other.title)”", 11, color: .systemOrange)
            col.addArrangedSubview(ask)
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 6
        func button(_ t: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            b.identifier = NSUserInterfaceItemIdentifier(d.id)
            return b
        }
        buttons.addArrangedSubview(button("Play", #selector(libPlay(_:))))
        buttons.addArrangedSubview(button("Export…", #selector(libExport(_:))))
        buttons.addArrangedSubview(button("Rebuild", #selector(libRebuild(_:))))
        buttons.addArrangedSubview(button("Sessions…", #selector(libSessions(_:))))
        buttons.addArrangedSubview(button("Rename…", #selector(libRename(_:))))
        buttons.addArrangedSubview(button("Delete…", #selector(libDelete(_:))))
        col.addArrangedSubview(buttons)

        box.addArrangedSubview(col)
        return box
    }

    /// The last frame of the video: the most recognisable single image of a
    /// drawing, and the one an artist identifies instantly.
    private func poster(for url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = .zero
        let end = CMTimeSubtract(asset.duration, CMTime(value: 1, timescale: 30))
        guard let cg = try? gen.copyCGImage(at: end.seconds > 0 ? end : .zero,
                                            actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// Videos sitting loose in the folder rather than inside a drawing: one file
    /// per session, named for the day it was made. Newest first, like the
    /// drawings above them.
    ///
    /// Numbered files are skipped: `.NNN.mp4` is an unfinished segment, not a
    /// video, and offering to play one would offer something unplayable.
    private func looseVideos(in dir: String) -> [URL] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".mp4") && !$0.hasPrefix(".") }
            .filter { n in
                let parts = n.dropLast(4).split(separator: ".")
                return !(parts.count >= 2 && Int(parts[parts.count - 1]) != nil)
            }
        return names.map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da > db
            }
    }

    /// A loose video, with the actions that actually apply to it. No Rebuild and
    /// no Sessions: it has no pieces behind it, and offering buttons that cannot
    /// work is worse than offering fewer.
    private func looseRow(_ url: URL) -> NSView {
        let box = NSStackView()
        box.orientation = .horizontal
        box.alignment = .top
        box.spacing = 12

        let thumb = HoverVideoView(url: url, image: poster(for: url))
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: 96).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 72).isActive = true
        box.addArrangedSubview(thumb)

        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        col.addArrangedSubview(lbl(url.deletingPathExtension().lastPathComponent, 13, bold: true))

        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var facts = prettyBytes(size)
        if let date { facts += " · \(f.string(from: date))" }
        col.addArrangedSubview(lbl(facts, 11, color: .secondaryLabelColor))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 6
        func button(_ t: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            // The path travels on the button, since a loose video has no id.
            b.identifier = NSUserInterfaceItemIdentifier(url.path)
            return b
        }
        buttons.addArrangedSubview(button("Play", #selector(libPlayFile(_:))))
        buttons.addArrangedSubview(button("Show in Finder", #selector(libRevealFile(_:))))
        buttons.addArrangedSubview(button("Delete…", #selector(libDeleteFile(_:))))
        col.addArrangedSubview(buttons)

        box.addArrangedSubview(col)
        return box
    }

    @objc func libPlayFile(_ sender: Any?) {
        guard let path = (sender as? NSButton)?.identifier?.rawValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func libRevealFile(_ sender: Any?) {
        guard let path = (sender as? NSButton)?.identifier?.rawValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func libDeleteFile(_ sender: Any?) {
        guard let path = (sender as? NSButton)?.identifier?.rawValue else { return }
        let url = URL(fileURLWithPath: path)
        let alert = NSAlert()
        alert.messageText = "Delete “\(url.lastPathComponent)”?"
        alert.informativeText = "This deletes the video. Your artwork is untouched."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // To the Trash, not unlinked: this is a video somebody may have spent an
        // evening making, and a wrong click should be undoable.
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refreshLibraryTab()
    }

    private func folderSize(_ path: String) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: URL(fileURLWithPath: path),
                                    includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func drawing(from sender: Any?) -> Drawing? {
        guard let id = (sender as? NSButton)?.identifier?.rawValue,
              let store = libStore else { return nil }
        return store.lib.drawing(id: id)
    }

    // MARK: - actions

    @objc func libPlay(_ sender: Any?) {
        guard let d = drawing(from: sender), let store = libStore else { return }
        let url = store.videoURL(d)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertUser("This drawing has no video yet. Press Rebuild to make one from its sessions.")
            return
        }
        // The system player, not one built here: it already does scrubbing,
        // fullscreen and everything else better than this app would.
        NSWorkspace.shared.open(url)
    }

    @objc func libRebuild(_ sender: Any?) {
        guard let d = drawing(from: sender), let store = libStore,
              let res = Bundle.main.resourcePath else { return }
        let enc = "\(res)/sai-timelapse-encoder"
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = store.rebuild(d.id, encoder: enc)
            DispatchQueue.main.async {
                if !ok { alertUser("Could not rebuild “\(d.title)”.") }
                self.refreshLibraryTab()
            }
        }
    }

    /// A length-capped copy, for posting. Separate file on purpose: the drawing
    /// keeps its full-length video, so exporting twice never compounds.
    @objc func libExport(_ sender: Any?) {
        guard let d = drawing(from: sender), let store = libStore,
              let res = Bundle.main.resourcePath else { return }
        let alert = NSAlert()
        alert.messageText = "Export “\(d.title)”"
        alert.informativeText = "The drawing keeps its full-length video; this makes a separate copy."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        popup.addItems(withTitles: LibraryExport.choiceTitles)
        popup.selectItem(at: storedTimelapseLengthIndex())
        alert.accessoryView = popup
        alert.addButton(withTitle: "Export…"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let seconds = LibraryExport.seconds(at: popup.indexOfSelectedItem)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = seconds > 0 ? "\(d.folder) (\(seconds)s).mp4" : "\(d.folder).mp4"
        panel.directoryURL = URL(fileURLWithPath: store.videosDir)
        guard panel.runModal() == .OK, let out = panel.url else { return }
        let enc = "\(res)/sai-timelapse-encoder"
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = store.export(d.id, seconds: seconds, to: out, encoder: enc)
            DispatchQueue.main.async {
                if ok { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                else { alertUser("Could not export “\(d.title)”.") }
            }
        }
    }

    /// The regrouping escape hatch: every session in this drawing, and the
    /// ability to take one out of it.
    @objc func libSessions(_ sender: Any?) {
        guard let d = drawing(from: sender), let store = libStore else { return }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let ordered = d.ordered
        let alert = NSAlert()
        alert.messageText = "Sessions in “\(d.title)”"
        alert.informativeText = "Each is one evening's recording. Taking one out makes it a "
            + "drawing of its own — nothing is deleted."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: ordered.map { "\(f.string(from: $0.startedAt)) — \($0.frames) frames" })
        alert.accessoryView = popup
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Take out of this drawing")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard ordered.count > 1 else {
            alertUser("This drawing has only one session — taking it out would leave nothing behind.")
            return
        }
        let piece = ordered[popup.indexOfSelectedItem]
        store.split(pieceFile: piece.file, from: d.id, title: d.title)
        rebuildAffected(store: store)
        refreshLibraryTab()
    }

    @objc func libRename(_ sender: Any?) {
        guard let d = drawing(from: sender), let store = libStore else { return }
        let alert = NSAlert()
        alert.messageText = "Rename this drawing"
        alert.informativeText = "This is a label only — it does not change which sessions belong together."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = d.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.rename(d.id, to: name)
        refreshLibraryTab()
    }

    @objc func libDelete(_ sender: Any?) {
        guard let d = drawing(from: sender), let store = libStore else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the recording of “\(d.title)”?"
        // The same promise the Discard button makes, for the same reason: the
        // one thing somebody needs to be certain of is that this is not their art.
        alert.informativeText = "This deletes \(d.pieces.count) session recording(s) and the video "
            + "made from them. Your artwork is untouched."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.delete(d.id)
        refreshLibraryTab()
    }

    private func rebuildAffected(store: LibraryStore) {
        guard let res = Bundle.main.resourcePath else { return }
        let enc = "\(res)/sai-timelapse-encoder"
        for d in store.lib.drawings { store.rebuild(d.id, encoder: enc) }
    }

    // MARK: - the question

    /// Ask about sessions that looked like continuations without being certain.
    ///
    /// Never during a session: the app's job while somebody is drawing is to be
    /// invisible, so this runs when a video has just been made. Everything it
    /// offers is also available from the Timelapses tab afterwards, so
    /// dismissing it costs nothing — the session is already filed and already
    /// has a video.
    @objc func askAboutPendingSessions() {
        let store = libStore ?? makeLibraryStore()
        libStore = store
        guard let p = store.lib.pending.first,
              let mine = store.lib.drawing(id: p.drawingId),
              let other = store.lib.drawing(id: p.candidateId) else { return }

        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        let when = other.lastDrawn.map { f.string(from: $0) } ?? "earlier"

        let alert = NSAlert()
        alert.messageText = "Is this the same drawing?"
        alert.informativeText = "Tonight's session looks like it carries on “\(other.title)”, "
            + "last drawn \(when). If it does, they become one video."
        // Two pictures, side by side. An artist recognises their own work
        // instantly; a question about canvas names is a question about our
        // bookkeeping, which is not something anyone should have to reason about.
        alert.accessoryView = comparison(left: store.videoURL(other), leftLabel: other.title,
                                         right: store.videoURL(mine), rightLabel: "Tonight")
        alert.addButton(withTitle: "Same drawing")
        alert.addButton(withTitle: "Separate drawings")
        alert.addButton(withTitle: "Decide later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.confirmSame(p)
            rebuildAffected(store: store)
        case .alertSecondButtonReturn:
            store.confirmSeparate(p)
        default:
            break                     // still pending, still shown in the tab
        }
        refreshLibraryTab()
    }

    private func comparison(left: URL, leftLabel: String, right: URL, rightLabel: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .top
        for (url, text) in [(left, leftLabel), (right, rightLabel)] {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .centerX
            col.spacing = 4
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 160).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 120).isActive = true
            iv.image = poster(for: url)
            col.addArrangedSubview(iv)
            col.addArrangedSubview(lbl(text, 11, color: .secondaryLabelColor))
            row.addArrangedSubview(col)
        }
        row.frame = NSRect(x: 0, y: 0, width: 344, height: 150)
        return row
    }
}

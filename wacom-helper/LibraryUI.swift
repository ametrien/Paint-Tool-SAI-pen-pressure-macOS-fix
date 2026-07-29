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

extension SetupController {

    // MARK: - the tab

    func buildLibraryTab() -> NSStackView {
        let tab = NSStackView()
        tab.orientation = .vertical
        tab.alignment = .leading
        tab.spacing = 10
        tab.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        tab.addArrangedSubview(lbl("Your drawings", 18, bold: true))
        tab.addArrangedSubview(
            lbl("Every evening you spend on a drawing is added to the same video.",
                11, color: .secondaryLabelColor))

        libStack = NSStackView()
        libStack.orientation = .vertical
        libStack.alignment = .leading
        libStack.spacing = 12
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = libStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        tab.addArrangedSubview(scroll)

        libFooter = lbl("", 11, color: .secondaryLabelColor)
        tab.addArrangedSubview(libFooter)
        libraryTab = tab
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
        guard !drawings.isEmpty else {
            libStack.addArrangedSubview(
                lbl("Nothing recorded yet. Draw in SAI with recording on, and your "
                    + "drawings will appear here.", 12, color: .secondaryLabelColor))
            libFooter.stringValue = ""
            return
        }

        for d in drawings { libStack.addArrangedSubview(row(for: d, store: store)) }

        let pieces = drawings.reduce(0) { $0 + $1.pieces.count }
        var footer = "\(drawings.count) drawing(s), \(pieces) session(s) — "
            + prettyBytes(folderSize(store.videosDir))
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

        let thumb = NSImageView()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: 96).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 72).isActive = true
        thumb.image = poster(for: store.videoURL(d))
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
        let choices = [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120),
                       ("Full length", 0)]
        let menu = NSMenu()
        for (t, _) in choices { menu.addItem(withTitle: t, action: nil, keyEquivalent: "") }
        let alert = NSAlert()
        alert.messageText = "Export “\(d.title)”"
        alert.informativeText = "The drawing keeps its full-length video; this makes a separate copy."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        popup.addItems(withTitles: choices.map(\.0))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Export…"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let seconds = choices[popup.indexOfSelectedItem].1

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

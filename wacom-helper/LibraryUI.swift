// LibraryUI.swift: the Videos tab, and the question the library asks.
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
    private var playerLayer: AVPlayerLayer?
    private var layerView: NSView?
    private var endObserver: Any?
    private(set) var isPreviewing = false

    /// The player layer's frame, for tests. Walking the layer tree from outside
    /// does not work headlessly — a subview's backing layer is not instantiated
    /// until it is displayed — so the view reports its own geometry.
    var previewFrame: CGRect { playerLayer?.frame ?? .zero }

    /// The one row currently playing. A pointer crossing three rows in a second
    /// otherwise leaves three videos running behind the one being looked at —
    /// invisible, since only the last is under the cursor, but audible in the
    /// fans and visible in the flicker as they all decode at once.
    private static weak var playing: HoverVideoView?

    init(url: URL, image: NSImage?) {
        self.url = url
        super.init(frame: .zero)
        // Nothing may escape the thumbnail's box. Layers are not clipped by
        // their superlayer unless told to be, and an unclipped AVPlayerLayer
        // draws the video at its own size straight over the rows below.
        wantsLayer = true
        layer?.masksToBounds = true
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

    /// Keep the player layer the size of the view.
    ///
    /// Belt and braces: the frame is also set when the preview starts, and with
    /// the thumbnail pinned to a fixed 96x72 that assignment is enough today —
    /// no test can tell this override from its absence. It earns its place the
    /// moment the still becomes resizable, which is exactly when a layer sized
    /// once from a stale bounds would start drawing over the rows below.
    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

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
        // One at a time, always.
        HoverVideoView.playing?.endPreview()

        let p = AVPlayer(url: url)
        p.isMuted = true                       // there is no audio, and never will be
        let host = NSView()
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        let pl = AVPlayerLayer(player: p)
        pl.videoGravity = .resizeAspect        // never stretch a drawing to fill
        pl.frame = bounds
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
        playerLayer = pl
        layerView = host
        isPreviewing = true
        HoverVideoView.playing = self
        needsLayout = true
        layoutSubtreeIfNeeded()
        p.play()
    }

    func endPreview() {
        guard isPreviewing else { return }
        player?.pause()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        layerView?.removeFromSuperview()
        layerView = nil
        player = nil
        isPreviewing = false
        if HoverVideoView.playing === self { HoverVideoView.playing = nil }
    }

    deinit {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
    }
}

extension SetupController {

    // MARK: - the tab

    static let libColumns = 3
    static let libGap: CGFloat = 12
    static let libListWidth: CGFloat = 540

    func buildLibraryTab() -> NSStackView {
        let tab = NSStackView()
        tab.orientation = .vertical
        tab.alignment = .leading
        tab.spacing = 10
        tab.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        tab.addArrangedSubview(lbl("Your videos", 18, bold: true))
        tab.addArrangedSubview(
            lbl("One video per drawing. Hover over a still to play it, double-click to open it.",
                11, color: .secondaryLabelColor))
        // The totals sit under the heading, where they read as a summary of the
        // grid, not beside the buttons, where they read as part of them.
        libFooter = lbl("", 11, color: .tertiaryLabelColor)
        tab.addArrangedSubview(libFooter)

        // What is being recorded right now. A session lives in the hidden
        // staging folder until SAI closes, so without this the tab showed
        // nothing at all about a drawing in progress, and looked as if
        // recording was not working.
        libLiveLabel = lbl("", 12, bold: true)
        libLiveLabel.lineBreakMode = .byTruncatingTail
        libLiveLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        libLiveHint = lbl("", 11, color: .secondaryLabelColor)
        let liveText = NSStackView(views: [libLiveLabel, libLiveHint])
        liveText.orientation = .vertical
        liveText.alignment = .leading
        liveText.spacing = 2
        let liveSpacer = NSView()
        liveSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        libLiveButton = NSButton(title: "Make video now", target: self, action: #selector(libMakeVideoNow))
        libLiveButton.bezelStyle = .rounded
        libLiveButton.controlSize = .small
        libLiveButton.font = NSFont.systemFont(ofSize: 11)
        libLiveButton.toolTip = "Makes the video of what is recorded so far. Recording carries on afterwards."
        libLiveDot = lbl("●", 12, color: .systemRed)
        libLiveDot.wantsLayer = true
        libLiveRow = NSStackView(views: [libLiveDot, liveText, liveSpacer, libLiveButton])
        libLiveRow.orientation = .horizontal
        libLiveRow.alignment = .centerY
        libLiveRow.spacing = 8
        libLiveRow.translatesAutoresizingMaskIntoConstraints = false
        libLiveRow.widthAnchor.constraint(equalToConstant: SetupController.libListWidth).isActive = true
        libLiveRow.isHidden = true
        libLiveShown = ""
        tab.addArrangedSubview(libLiveRow)

        let grid = LibraryGridView()
        grid.owner = self
        libStack = grid
        libStack.orientation = .vertical
        libStack.alignment = .leading
        libStack.spacing = 14
        libStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        // A stack view used as a documentView must be laid out by constraints.
        // Left on autoresizing translation it keeps its zero frame, and every
        // card inside it is present, unhidden, and drawn at (0,0,0,0): the tab
        // renders as a blank rectangle. This is the same trap the tab bar in
        // SetupWindow.swift documents, in the opposite direction.
        libStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        // THE TRAP: NSClipView is not flipped, so a grid shorter than the
        // scroll view settles at the BOTTOM of it. One drawing showed up a
        // hand's width below the heading with nothing above it.
        scroll.contentView = TopAnchoredClipView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
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
        // An exact height, never a minimum: with a minimum the grid grew to fill
        // the tab and pushed the bar below it off the bottom. The constant
        // follows the content (see refreshLibraryTab) up to a cap, so one drawing
        // is not followed by a screenful of nothing.
        libScrollHeight = scroll.heightAnchor.constraint(equalToConstant: 300)
        libScrollHeight.isActive = true
        scroll.widthAnchor.constraint(equalToConstant: SetupController.libListWidth).isActive = true
        tab.addArrangedSubview(scroll)
        tab.setCustomSpacing(12, after: scroll)

        // What the selection can do, in one place under the grid. Before this,
        // every row carried its own Play, Export and More, so a list of twenty
        // drawings was sixty buttons, and deleting five meant five trips
        // through the same menu and the same question.
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 6
        libStatus = lbl("", 11, color: .secondaryLabelColor)
        libStatus.lineBreakMode = .byTruncatingTail
        libStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(libStatus)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        bar.addArrangedSubview(spacer)
        func barButton(_ t: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            bar.addArrangedSubview(b)
            return b
        }
        libPlayButton = barButton("Play", #selector(libPlaySelected))
        libExportButton = barButton("Export…", #selector(libExportSelected))
        libRevealButton = barButton("Show in Finder", #selector(libRevealSelected))
        libDeleteButton = barButton("Delete…", #selector(libDeleteSelected))
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: SetupController.libListWidth).isActive = true
        tab.addArrangedSubview(bar)

        libraryTab = tab
        refreshLibraryTab()
        return tab
    }

    /// Rebuild the grid from the index on disk. Cheap enough to call on every
    /// tab switch, which keeps it honest: the index is the truth, and this view
    /// holds no state of its own beyond which cards are selected.
    func refreshLibraryTab() {
        guard libStack != nil else { return }
        let store = makeLibraryStore()
        libStore = store
        for v in libStack.arrangedSubviews { v.removeFromSuperview() }
        libCards = [:]
        libOrder = []

        let drawings = store.lib.drawings.sorted {
            ($0.lastDrawn ?? .distantPast) > ($1.lastDrawn ?? .distantPast)
        }
        addGrid(drawings.map { card(for: $0, store: store) })

        // Videos that are simply IN the folder: everything recorded before
        // drawings existed as a concept, and anything a rebuild has not claimed.
        // They are real videos, and a grid that ignores them while announcing
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
            addGrid(loose.map { looseCard($0) })
        }

        // A deleted or regrouped video must not stay selected while invisible.
        libSelection.keep(only: libOrder)
        applyLibrarySelection()

        defer { fitLibraryHeight() }
        refreshLibraryLive(fresh: true)
        if drawings.isEmpty && loose.isEmpty {
            libStack.addArrangedSubview(
                lbl("Nothing recorded yet. Draw in SAI with recording on, and your "
                    + "drawings will appear here.", 12, color: .secondaryLabelColor))
            libFooter.stringValue = ""
            libFooter.isHidden = true
            return
        }

        let pieces = drawings.reduce(0) { $0 + $1.pieces.count }
        var parts: [String] = []
        if !drawings.isEmpty {
            parts.append(counted(drawings.count, "drawing"))
            parts.append(counted(pieces, "session"))
        }
        if !loose.isEmpty { parts.append(counted(loose.count, "older video")) }
        let size = prettyFileSize(folderSize(store.videosDir))
        if !size.isEmpty { parts.append(size) }
        if !store.lib.pending.isEmpty {
            parts.append(counted(store.lib.pending.count, "session") + " to confirm")
        }
        libFooter.stringValue = parts.joined(separator: " · ")
        libFooter.isHidden = false
    }

    /// The sessions still in staging.
    ///
    /// The usual call costs one directory listing and nothing else: the
    /// sidecars are only opened when the SET of sessions changed, which is
    /// when a recording starts or ends. `fresh` forgets that, for a tab that
    /// has just been rebuilt from disk.
    func liveSessions(fresh: Bool = false) -> [LiveSession] {
        let store = libStore ?? makeLibraryStore()
        let staging = store.stagingDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: staging)) ?? []
        let prefixes = LibraryCore.unfinishedSessions(in: names)
        let key = staging + "\n" + prefixes.joined(separator: "\n")
        if !fresh, key == libLiveKey { return libLiveSessions }
        libLiveKey = key
        libLiveSessions = readLiveSessions(prefixes, staging: staging, store: store)
        return libLiveSessions
    }

    private func readLiveSessions(_ prefixes: [String], staging: String, store: LibraryStore) -> [LiveSession] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return prefixes.compactMap { prefix in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: staging)
                                           .appendingPathComponent(prefix + ".json")),
                  let side = try? dec.decode(SessionSidecar.self, from: data) else { return nil }
            // The same question filing asks when SAI closes, asked early, so the
            // line can say the frames are going into a drawing already listed.
            // Only a certain match counts: "might be" is asked about later.
            var continues = false
            if case .same = LibraryCore.classify(opening: side.opening, title: side.title, path: nil,
                                                 candidates: store.lib.drawings,
                                                 sessionFile: prefix + ".mp4", declined: store.lib) {
                continues = true
            }
            return LiveSession(title: side.title, continues: continues)
        }
    }

    /// Bring the "Recording now" line up to date. Called every few seconds
    /// while the Videos tab is showing, so it must stay cheap: it lists one
    /// folder, and touches the views only when the text changed. `recording`
    /// is whether the encoder is running; the tests pass it, the app asks.
    func refreshLibraryLive(recording: Bool? = nil, fresh: Bool = false) {
        guard libLiveRow != nil else { return }
        let sessions = liveSessions(fresh: fresh)
        let rec = recording ?? (g_liveEncoder?.isRunning ?? false)
        let note = libMakingVideo ? "Making the video" : LibraryCore.liveNote(sessions, recording: rec)
        let hint = libMakingVideo ? "" : LibraryCore.liveHint(sessions, recording: rec)
        let shown = note + "\n" + hint
        guard shown != libLiveShown else { return }
        let hadOne = !libLiveShown.isEmpty && libLiveShown != "\n"
        libLiveShown = shown
        libLiveLabel.stringValue = note
        libLiveHint.stringValue = hint
        libLiveHint.isHidden = hint.isEmpty
        libLiveButton.isEnabled = !libMakingVideo
        setLivePulse(rec && !note.isEmpty && !libMakingVideo)
        if libLiveRow.isHidden != note.isEmpty {
            libLiveRow.isHidden = note.isEmpty
            applyLayout()
        }
        // The session has just gone from staging: SAI closed, or a video was
        // made. That is the moment its drawing appears or grows, so the grid is
        // rebuilt once, here, not on every tick.
        if note.isEmpty && hadOne { refreshLibraryTab() }
    }

    /// The red dot breathes while a recording is going on, and only then.
    ///
    /// A Core Animation on the dot's layer, deliberately: the window server
    /// fades it, so no timer fires and no code of ours runs per frame on the
    /// thread the pen is read on. A leftover session gets a still grey dot,
    /// because a pulsing red one says "recording" whatever the words say.
    /// With Reduce Motion on, the dot stays red and still.
    func setLivePulse(_ on: Bool) {
        guard let dot = libLiveDot else { return }
        dot.textColor = on || libMakingVideo ? .systemRed : .tertiaryLabelColor
        let key = "pulse"
        let moving = on && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard moving else { dot.layer?.removeAnimation(forKey: key); return }
        guard dot.layer?.animation(forKey: key) == nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.35              // light: it dims, it never disappears
        a.duration = 1.4
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Survives the window being minimized and brought back.
        a.isRemovedOnCompletion = false
        dot.layer?.add(a, forKey: key)
    }
    var livePulseIsOn: Bool { libLiveDot?.layer?.animation(forKey: "pulse") != nil }

    /// The button on that line: the video so far, without leaving the tab.
    @objc func libMakeVideoNow() {
        makeVideoNow(revealInFinder: false)
    }

    /// Cards in rows of three, in the order given.
    private func addGrid(_ cards: [LibraryCardView]) {
        let cols = SetupController.libColumns
        for start in stride(from: 0, to: cards.count, by: cols) {
            let row = NSStackView(views: Array(cards[start..<min(start + cols, cards.count)]))
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = SetupController.libGap
            libStack.addArrangedSubview(row)
        }
        for c in cards {
            libCards[c.key] = c
            libOrder.append(c.key)
        }
    }

    /// Size the grid to what it holds, up to a cap; past the cap it scrolls.
    private func fitLibraryHeight() {
        guard let h = libScrollHeight else { return }
        libStack.layoutSubtreeIfNeeded()
        let want = min(max(libStack.fittingSize.height, 60), 400)
        if abs(h.constant - want) > 0.5 {
            h.constant = want
            applyLayout()
        }
    }

    /// "1 session", "3 sessions". "session(s)" is what software says when it
    /// could not be bothered, and the number is right there.
    func counted(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private var libCardWidth: CGFloat {
        let cols = CGFloat(SetupController.libColumns)
        return ((SetupController.libListWidth - (cols - 1) * SetupController.libGap) / cols).rounded(.down)
    }

    /// One drawing: its still, its name, and two short lines of facts.
    private func card(for d: Drawing, store: LibraryStore) -> LibraryCardView {
        let url = store.videoURL(d)
        var first = [counted(d.pieces.count, "session"), counted(d.totalFrames, "frame")]
        let length = prettyDuration(videoSeconds(url))
        if !length.isEmpty { first.append(length) }
        var second: [String] = []
        let size = prettyFileSize(fileSize(url))
        if !size.isEmpty { second.append(size) }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        if let last = d.lastDrawn { second.append(f.string(from: last)) }
        // A session waiting on an answer is shown on the drawing itself, not
        // only in a prompt that may have been dismissed.
        var warning: String?
        if let p = store.lib.pending.first(where: { $0.drawingId == d.id }),
           let other = store.lib.drawing(id: p.candidateId) {
            warning = "Might continue “\(other.title)”"
        }
        let c = LibraryCardView(key: LibrarySelection.drawingKey(d.id), url: url, image: poster(for: url),
                                title: d.title.isEmpty ? d.folder : d.title,
                                lines: [first.joined(separator: " · "), second.joined(separator: " · ")],
                                warning: warning, width: libCardWidth)
        wire(c)
        return c
    }

    /// A loose video. It has no pieces behind it, so its menu offers no
    /// Rebuild and no Sessions: buttons that cannot work are worse than fewer.
    private func looseCard(_ url: URL) -> LibraryCardView {
        var first: [String] = []
        let length = prettyDuration(videoSeconds(url))
        if !length.isEmpty { first.append(length) }
        let size = prettyFileSize(fileSize(url))
        if !size.isEmpty { first.append(size) }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let c = LibraryCardView(key: LibrarySelection.fileKey(url.path), url: url, image: poster(for: url),
                                title: url.deletingPathExtension().lastPathComponent,
                                lines: [first.joined(separator: " · "), date.map { f.string(from: $0) } ?? ""],
                                warning: nil, width: libCardWidth)
        wire(c)
        return c
    }

    private func wire(_ c: LibraryCardView) {
        c.onClick = { [weak self] card, event in self?.libClicked(card, event) }
        c.onDoubleClick = { [weak self] card in self?.libOpen(card.key) }
        c.menuProvider = { [weak self] card in self?.libMenu(for: card) }
    }

    // MARK: - selection

    func libClicked(_ card: LibraryCardView, _ event: NSEvent) {
        let flags = event.modifierFlags
        let mod: LibrarySelection.Modifier = flags.contains(.shift) ? .range
            : (flags.contains(.command) ? .toggle : .none)
        libSelection.click(card.key, modifier: mod, order: libOrder)
        // So Delete, ⌘A and Escape reach the grid.
        libStack.window?.makeFirstResponder(libStack)
        applyLibrarySelection()
    }

    func libSelectAll() {
        libSelection.selectAll(libOrder)
        applyLibrarySelection()
    }

    func libDeselectAll() {
        libSelection.clear()
        applyLibrarySelection()
    }

    /// Paint the selection onto the cards and the bar.
    func applyLibrarySelection() {
        for (k, c) in libCards { c.isSelected = libSelection.contains(k) }
        let sel = libSelection.ordered(libOrder)
        libStatus?.stringValue = libOrder.isEmpty ? "" : LibrarySelection.status(selected: sel.count)
        libPlayButton?.isEnabled = sel.count == 1
        libExportButton?.isEnabled = sel.count == 1 && LibrarySelection.drawingId(sel[0]) != nil
        libRevealButton?.isEnabled = !sel.isEmpty
        libDeleteButton?.isEnabled = !sel.isEmpty
        libDeleteButton?.title = sel.count > 1 ? "Delete \(sel.count)…" : "Delete…"
    }

    /// Right-click. Several selected: what can be done to all of them. One:
    /// everything that can be done to it.
    func libMenu(for card: LibraryCardView) -> NSMenu {
        libSelection.rightClick(card.key)
        applyLibrarySelection()
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ t: String, _ sel: Selector, _ ident: String? = nil) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self
            if let ident { i.identifier = NSUserInterfaceItemIdentifier(ident) }
            menu.addItem(i)
        }
        let sel = libSelection.ordered(libOrder)
        if sel.count > 1 {
            item("Show \(sel.count) in Finder", #selector(libRevealSelected))
            menu.addItem(.separator())
            item("Delete \(sel.count) Videos…", #selector(libDeleteSelected))
            return menu
        }
        if let id = LibrarySelection.drawingId(card.key) {
            item("Play", #selector(libPlay(_:)), id)
            item("Export…", #selector(libExport(_:)), id)
            item("Show in Finder", #selector(libRevealSelected))
            menu.addItem(.separator())
            item("Rename…", #selector(libRename(_:)), id)
            item("Sessions…", #selector(libSessions(_:)), id)
            item("Rebuild video", #selector(libRebuild(_:)), id)
        } else if let path = LibrarySelection.filePath(card.key) {
            item("Play", #selector(libPlayFile(_:)), path)
            item("Show in Finder", #selector(libRevealSelected))
        }
        menu.addItem(.separator())
        item("Delete…", #selector(libDeleteSelected))
        return menu
    }

    /// Double-click, Return or Space, or Play in the bar.
    func libOpen(_ key: String) {
        if let id = LibrarySelection.drawingId(key), let d = libStore?.lib.drawing(id: id) {
            playDrawing(d)
        } else if let path = LibrarySelection.filePath(key) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    @objc func libPlaySelected() {
        let sel = libSelection.ordered(libOrder)
        guard sel.count == 1 else { return }
        libOpen(sel[0])
    }

    @objc func libExportSelected() {
        let sel = libSelection.ordered(libOrder)
        guard sel.count == 1, let id = LibrarySelection.drawingId(sel[0]),
              let d = libStore?.lib.drawing(id: id) else { return }
        exportDrawing(d)
    }

    @objc func libRevealSelected() {
        guard let store = libStore else { return }
        let urls: [URL] = libSelection.ordered(libOrder).compactMap { key in
            if let id = LibrarySelection.drawingId(key), let d = store.lib.drawing(id: id) {
                let v = store.videoURL(d)
                return FileManager.default.fileExists(atPath: v.path) ? v : store.folderURL(d)
            }
            return LibrarySelection.filePath(key).map { URL(fileURLWithPath: $0) }
        }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc func libDeleteSelected() {
        deleteLibraryKeys(libSelection.ordered(libOrder), ask: true)
    }

    /// Delete several at once, after one question that says exactly what goes.
    ///
    /// To the Trash, never unlinked: these are videos somebody may have spent
    /// evenings making, and a selection one Shift-click too wide should be one
    /// trip to the Trash from being undone.
    @discardableResult
    func deleteLibraryKeys(_ keys: [String], ask: Bool) -> [String] {
        guard let store = libStore, !keys.isEmpty else { return [] }
        let drawings = keys.compactMap(LibrarySelection.drawingId).compactMap { store.lib.drawing(id: $0) }
        let files = keys.compactMap(LibrarySelection.filePath)
        let names = drawings.map { $0.title.isEmpty ? $0.folder : $0.title }
            + files.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        if ask {
            let alert = NSAlert()
            alert.messageText = LibrarySelection.deleteTitle(names: names)
            var text = LibrarySelection.deleteDetail(drawings: drawings.count,
                                                     sessions: drawings.reduce(0) { $0 + $1.pieces.count },
                                                     older: files.count)
            if names.count > 1 {
                let shown = names.prefix(6).joined(separator: ", ")
                text += "\n\n" + shown + (names.count > 6 ? ", and \(names.count - 6) more" : "")
            }
            alert.informativeText = text
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return [] }
        }
        var failed: [String] = []
        for d in drawings where !store.trash(d.id) { failed.append(d.title) }
        for p in files {
            do { try moveToTrash(URL(fileURLWithPath: p)) }
            catch { failed.append(URL(fileURLWithPath: p).lastPathComponent) }
        }
        libSelection.clear()
        refreshLibraryTab()
        // Only said out loud when a person asked: `ask: false` is the tests'
        // path, and a modal alert there would hang the run.
        if !failed.isEmpty && ask {
            alertUser("Could not move these to the Trash: " + failed.joined(separator: ", ") + ".")
        }
        return failed
    }

    /// How long a video runs. Read from the file rather than worked out from
    /// frames and fps, because a rebuilt drawing may have been re-timed and only
    /// the file knows.
    func videoSeconds(_ url: URL) -> Double {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let d = AVURLAsset(url: url).duration.seconds
        return d.isFinite && d > 0 ? d : 0
    }

    /// "8s", "1m 14s". Timelapses are short, so seconds matter and hours do not.
    func prettyDuration(_ s: Double) -> String {
        guard s > 0 else { return "" }
        let total = Int(s.rounded())
        if total < 60 { return "\(max(1, total))s" }
        return "\(total / 60)m \(total % 60)s"
    }

    /// prettyBytes() reports whole megabytes, which is right for a folder of raw
    /// frames and wrong for one video: line art encodes so small that every row
    /// read "0 MB".
    func prettyFileSize(_ b: Int64) -> String {
        if b <= 0 { return "" }
        if b < 1_000_000 { return String(format: "%.0f KB", Double(b) / 1000) }
        return prettyBytes(b)
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
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

    @objc func libPlayFile(_ sender: Any?) {
        guard let path = (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
        // From a button or from an item in the More menu: both carry the id.
        guard let id = (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue,
              let store = libStore else { return nil }
        return store.lib.drawing(id: id)
    }

    // MARK: - actions

    @objc func libPlay(_ sender: Any?) {
        guard let d = drawing(from: sender) else { return }
        playDrawing(d)
    }

    func playDrawing(_ d: Drawing) {
        guard let store = libStore else { return }
        let url = store.videoURL(d)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertUser("This drawing has no video yet. Right-click it and choose Rebuild video to make one from its sessions.")
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
        guard let d = drawing(from: sender) else { return }
        exportDrawing(d)
    }

    func exportDrawing(_ d: Drawing) {
        guard let store = libStore, let res = Bundle.main.resourcePath else { return }
        let alert = NSAlert()
        alert.messageText = "Export “\(d.title)”"
        alert.informativeText = "The drawing keeps its full-length video; this makes a separate copy."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        popup.addItems(withTitles: LibraryExport.choiceTitles)
        popup.selectItem(at: storedTimelapseLengthIndex())
        alert.accessoryView = popup
        alert.addButton(withTitle: "Export…"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Remembered for next time, in place of the separate "Export length"
        // setting this dialog used to start from.
        storeTimelapseLengthIndex(popup.indexOfSelectedItem)
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
            + "drawing of its own. Nothing is deleted."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: ordered.map { "\(f.string(from: $0.startedAt)) · \($0.frames) frames" })
        alert.accessoryView = popup
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Take out of this drawing")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard ordered.count > 1 else {
            alertUser("This drawing has only one session. Taking it out would leave nothing behind.")
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
        alert.informativeText = "This is a label only. It does not change which sessions belong together."
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

/// A clip view that keeps short content at the top. NSClipView is unflipped, so
/// without this a one-row list sits at the bottom of its scroll view.
final class TopAnchoredClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// The grid's document view. Takes the keyboard after a card is clicked, so
/// Delete, ⌘A, Escape and Return work on the selection, and clears the
/// selection when the empty space between cards is clicked.
final class LibraryGridView: NSStackView {
    weak var owner: SetupController?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 51, 117: owner?.libDeleteSelected()          // delete, forward delete
        case 53: owner?.libDeselectAll()                  // escape
        case 36, 76, 49: owner?.libPlaySelected()         // return, enter, space
        default:
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "a" {
                owner?.libSelectAll()
            } else {
                super.keyDown(with: e)
            }
        }
    }

    override func selectAll(_ sender: Any?) { owner?.libSelectAll() }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        owner?.libDeselectAll()
    }
}

/// One video in the grid: its still (which plays on hover), its name, and two
/// lines of facts. The whole card is one click target, so a click on the
/// still, the name or the gap between them all select it.
final class LibraryCardView: NSView {
    let key: String
    let thumb: HoverVideoView
    var onClick: ((LibraryCardView, NSEvent) -> Void)?
    var onDoubleClick: ((LibraryCardView) -> Void)?
    var menuProvider: ((LibraryCardView) -> NSMenu?)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            badge.isHidden = !isSelected
            needsDisplay = true
            updateColors()
        }
    }
    private let badge = NSImageView()
    private static let pad: CGFloat = 6

    init(key: String, url: URL, image: NSImage?, title: String, lines: [String], warning: String?, width: CGFloat) {
        self.key = key
        thumb = HoverVideoView(url: url, image: image)
        super.init(frame: .zero)
        let pad = LibraryCardView.pad
        let inner = width - 2 * pad
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: inner).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: (inner * 0.7).rounded()).isActive = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.borderWidth = 0

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.toolTip = title
        var views: [NSView] = [thumb, titleField]
        for line in lines where !line.isEmpty {
            let l = NSTextField(labelWithString: line)
            l.font = .systemFont(ofSize: 10.5)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
            views.append(l)
        }
        if let warning {
            let w = NSTextField(labelWithString: warning)
            w.font = .systemFont(ofSize: 10.5)
            w.textColor = .systemOrange
            w.lineBreakMode = .byTruncatingTail
            views.append(w)
        }
        for v in views.dropFirst() {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(7, after: thumb)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad - 2),
        ])

        // A tick in the corner of a selected still, as in Photos: the tinted
        // background alone is easy to miss on a pale drawing.
        badge.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")
        badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            .applying(.init(paletteColors: [.white, .controlAccentColor]))
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 5),
            badge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -5),
        ])
        updateColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Every point inside the card is the card's: the still and the labels
    /// would otherwise take the click for themselves. Hover still reaches the
    /// still, because tracking areas do not go through hitTest.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount >= 2 { onDoubleClick?(self) } else { onClick?(self, e) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(self) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Layer colours are fixed values, so they are worked out again whenever
    /// light or dark mode changes.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumb.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            thumb.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        thumb.layer?.borderWidth = isSelected ? 2.5 : 0
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }
}

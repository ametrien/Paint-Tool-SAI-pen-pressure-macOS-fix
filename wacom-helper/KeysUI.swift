// KeysUI.swift — the Keys tab: what each Mac modifier key sends to SAI.
//
// The mapping itself and why the defaults are what they are live in
// KeysCore.swift. This file is only the controls, and a small pad that shows
// what a key press would turn into.

import AppKit

extension SetupController {

    /// A label that wraps at the tab's width instead of running off the edge.
    private func para(_ s: String, _ size: CGFloat, color: NSColor) -> NSTextField {
        let l = lbl(s, size, color: color)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.preferredMaxLayoutWidth = rowWidth
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        return l
    }

    func buildKeysTab() -> NSStackView {
        let tab = NSStackView()
        tab.orientation = .vertical
        tab.alignment = .leading
        tab.spacing = 10
        tab.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        tab.addArrangedSubview(lbl("Keys", 18, bold: true))
        let intro = para("What each Mac key sends to SAI. ⌘ as Ctrl gives you ⌘Z, ⌘S and the other "
                         + "shortcuts; Alt is what SAI uses for the eyedropper.",
                         11, color: .secondaryLabelColor)
        tab.addArrangedSubview(intro)

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        keyPopups = [:]
        for k in MacModifierKey.allCases {
            let p = NSPopUpButton()
            p.translatesAutoresizingMaskIntoConstraints = false
            p.widthAnchor.constraint(equalToConstant: 270).isActive = true
            p.addItems(withTitles: [k.whenOn.label, k.whenOff.label])
            p.identifier = NSUserInterfaceItemIdentifier(k.rawValue)
            p.target = self
            p.action = #selector(keyRoleChanged(_:))
            keyPopups[k] = p
            grid.addRow(with: [lbl(k.label, 12, bold: true), p])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        tab.setCustomSpacing(14, after: intro)
        tab.addArrangedSubview(grid)

        keysWarning = para("", 11, color: .systemOrange)
        tab.addArrangedSubview(keysWarning)

        // Wine reads these once, when SAI starts. Saying so in a grey footnote
        // was not enough: a change that does nothing reads as a change that is
        // broken. So when it cannot take effect yet, this says it in plain view.
        keysRestartNote = para("", 12, color: .systemOrange)
        keysRestartNote.font = .boldSystemFont(ofSize: 12)
        keysRestartNote.isHidden = true
        tab.addArrangedSubview(keysRestartNote)

        keysNote = para("", 11, color: .secondaryLabelColor)   // text set in refreshKeysTab()
        tab.addArrangedSubview(keysNote)

        let reset = NSButton(title: "Restore defaults", target: self, action: #selector(keysRestoreDefaults))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        tab.addArrangedSubview(reset)

        tab.setCustomSpacing(20, after: reset)
        tab.addArrangedSubview(lbl("Try a key", 13, bold: true))
        let probe = KeyProbeView { storedKeyMapping() }
        probe.translatesAutoresizingMaskIntoConstraints = false
        probe.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        probe.heightAnchor.constraint(equalToConstant: 64).isActive = true
        tab.addArrangedSubview(probe)
        let probeHint = para("Press a key or a combination while the box is selected. It shows what "
                             + "the settings above turn it into. This runs here, not inside SAI.",
                             10, color: .secondaryLabelColor)
        tab.addArrangedSubview(probeHint)

        keysTab = tab
        refreshKeysTab()
        return tab
    }

    func refreshKeysTab() {
        let m = storedKeyMapping()
        for (k, p) in keyPopups { p.selectItem(at: m.role(k) == k.whenOn ? 0 : 1) }
        var warn: [String] = []
        if !m.hasAlt {
            warn.append("No key sends Alt, so SAI's Alt shortcuts (hold Alt for the eyedropper) "
                        + "can't be used.")
        }
        keysWarning.stringValue = warn.joined(separator: "\n")
        keysWarning.isHidden = warn.isEmpty
        // Both Option keys as Alt is the default, so it is a hint, not a warning:
        // an orange line on a fresh install would read as something wrong.
        keysNote.stringValue = m.canTypeSpecialCharacters
            ? "Type @, € and other ⌥ characters with the Option key set to “types special characters”.\n"
              + "SAI reads these when it starts, so a change applies the next time SAI opens."
            : "Type @, € or other characters with ⌥ on your keyboard layout? Set one Option key "
              + "to “types special characters” and type them with that one.\n"
              + "SAI reads these when it starts, so a change applies the next time SAI opens."
        refreshKeysRestartNote()
        applyLayout()
    }

    /// Shown only while it is true: a key was changed while SAI was open. Goes
    /// away by itself once SAI has been closed.
    func refreshKeysRestartNote() {
        guard keysRestartNote != nil else { return }
        if keysNeedSAIRestart && !saiProcessRunning() { keysNeedSAIRestart = false }
        let show = keysNeedSAIRestart
        keysRestartNote.stringValue = show
            ? "⚠️ SAI is open and still uses the old keys. Save your work, quit SAI and launch it "
              + "again to use the new ones."
            : ""
        if keysRestartNote.isHidden == show {
            keysRestartNote.isHidden = !show
            applyLayout()
        }
    }

    /// Write the keys into Wine straight away rather than at the next Launch,
    /// so that SAI started any other way gets them too. In the background:
    /// each `wine reg` call takes a moment.
    private func applyKeysNow() {
        if saiProcessRunning() { keysNeedSAIRestart = true }
        let wine = g_wine.isEmpty ? (wineBin() ?? "") : g_wine
        guard !wine.isEmpty, FileManager.default.fileExists(atPath: appPrefix) else { return }
        DispatchQueue.global(qos: .userInitiated).async { applyWineShortcutRemap(wine) }
    }

    @objc func keyRoleChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let k = MacModifierKey(rawValue: raw) else { return }
        var m = storedKeyMapping()
        m.set(k, to: sender.indexOfSelectedItem == 0 ? k.whenOn : k.whenOff)
        storeKeyMapping(m)
        applyKeysNow()
        refreshKeysTab()
    }

    @objc func keysRestoreDefaults() {
        storeKeyMapping(.defaults)
        applyKeysNow()
        refreshKeysTab()
    }
}

/// Shows what a key press turns into under the current mapping. A prediction
/// from the settings, not a reading from inside Wine, and it says so.
final class KeyProbeView: NSView {
    private let mapping: () -> KeyMapping
    private let text = NSTextField(labelWithString: "Click here, then press a key")

    init(mapping: @escaping () -> KeyMapping) {
        self.mapping = mapping
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        text.font = NSFont.systemFont(ofSize: 13)
        text.textColor = .secondaryLabelColor
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.centerXAnchor.constraint(equalTo: centerXAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
        ])
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool {
        defer { updateBorder() }
        show("Press a key…", dim: true)
        return true
    }
    override func resignFirstResponder() -> Bool {
        defer { updateBorder() }
        show("Click here, then press a key", dim: true)
        return true
    }
    override func viewDidChangeEffectiveAppearance() { updateBorder() }

    private func updateBorder() {
        let focused = window?.firstResponder === self
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (focused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4).cgColor
        }
        layer?.borderWidth = focused ? 2 : 1
    }

    private func show(_ s: String, dim: Bool = false) {
        text.stringValue = s
        text.textColor = dim ? .secondaryLabelColor : .labelColor
    }

    // Device-dependent modifier bits (IOKit's NX_DEVICE*KEYMASK): the only way
    // to tell left from right, which is the whole point of this tab.
    private static let bits: [(MacModifierKey, UInt)] = [
        (.leftOption, 0x20), (.rightOption, 0x40), (.leftCommand, 0x08), (.rightCommand, 0x10),
    ]
    private func held(_ e: NSEvent) -> [MacModifierKey] {
        let raw = e.modifierFlags.rawValue
        return Self.bits.filter { raw & $0.1 != 0 }.map { $0.0 }
    }

    override func flagsChanged(with e: NSEvent) {
        let keys = held(e)
        guard !keys.isEmpty else { show("Press a key…", dim: true); return }
        let m = mapping()
        show(keys.map { "\($0.label) → \(describe(m.role($0)))" }.joined(separator: "   "))
    }

    private func describe(_ r: KeyRole) -> String {
        r == .typing ? "Option (for typing characters, SAI doesn't see it)" : "SAI gets \(r.label)"
    }

    override func keyDown(with e: NSEvent) {
        let m = mapping()
        let keys = held(e)
        let base = (e.charactersIgnoringModifiers ?? "").uppercased()
        let name = base == " " ? "Space" : base
        let roles = keys.map { m.role($0) }
        let windowsMods = Set(roles.filter { $0 != .typing }.map { $0.label })
        let typing = roles.contains(.typing)
        var out: [String] = []
        if !windowsMods.isEmpty {
            out.append("SAI gets " + (["Ctrl", "Alt"].filter { windowsMods.contains($0) } + [name])
                .joined(separator: "+"))
        }
        if typing && windowsMods.isEmpty, let c = e.characters, !c.isEmpty {
            out.append("types “\(c)”")
        }
        if out.isEmpty { out.append("SAI gets \(name)") }
        show(keys.map { $0.label.components(separatedBy: " ").prefix(2).joined(separator: " ") }
            .joined(separator: " + ") + (keys.isEmpty ? "" : " + ") + name + "  →  " + out.joined(separator: ", "))
    }

    /// ⌘-combinations go to the menu first; while this box has focus they are
    /// shown instead. ⌘Q is let through: it quits on a Mac, inside SAI too.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown else { return false }
        if e.charactersIgnoringModifiers?.lowercased() == "q" { return false }
        keyDown(with: e)
        return true
    }
}

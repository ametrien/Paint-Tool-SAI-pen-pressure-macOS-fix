// PopupMenuTests.swift — the pen feel dropdown on a real NSPopUpButton,
// offscreen: no window is shown, nothing is clicked, the cursor never moves.
//
// The regression this guards (after 0.3.10): the setup window's 1 s refresh
// kept firing while the dropdown was open and swapped in a new menu, so the
// item the user then picked belonged to a menu the popup no longer had. The
// pick was dropped and the dropdown stayed on Normal. See syncPopupMenu.
//
// How a pick is replayed: NSMenu.performActionForItem(at:) is the call menu
// tracking ends with when the user releases on an item. Holding on to the
// menu from BEFORE a tick and picking from it is exactly "the menu on screen
// was opened before the refresh ran".

import AppKit

var failures = 0
func expect(_ cond: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

typealias Tag = PenFeelCore.Tag

/// A stand-in for SetupController: the same state, the same sync, and a
/// feelChanged that applies presets and profiles the way PenUI.swift does.
final class FeelWindow: NSObject {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    var feel = PenFeel.normal
    var profiles: [PenProfile] = []
    var selectedProfile: String?
    var actions = 0

    override init() {
        super.init()
        popup.target = self
        popup.action = #selector(changed)
        sync()
    }
    /// What syncFeelControls does with the popup (PenUI.swift).
    func sync() {
        if let m = PenFeelCore.matchName(feel, profiles: profiles),
           profiles.contains(where: { $0.name == m }) { selectedProfile = m }
        let m = PenFeelCore.menu(for: feel, profiles: profiles, selectedProfile: selectedProfile)
        syncPopupMenu(popup, m.entries, selectTag: m.selected)
    }
    /// What feelChanged does for a preset or a profile (PenUI.swift).
    @objc func changed() {
        actions += 1
        let tag = popup.selectedItem?.tag ?? Tag.custom
        if (Tag.preset..<(Tag.preset + PenFeelCore.presets.count)).contains(tag) {
            selectedProfile = nil
            feel = PenFeelCore.presets[tag - Tag.preset].feel
        } else if (Tag.profile..<(Tag.profile + profiles.count)).contains(tag) {
            selectedProfile = profiles[tag - Tag.profile].name
            feel = profiles[tag - Tag.profile].feel
        }
        sync()
    }
    /// The user opens the dropdown, `ticks` refreshes run while it is open,
    /// then they release on `title` in the menu they are looking at.
    func pick(_ title: String, ticksWhileOpen ticks: Int) {
        let onScreen = popup.menu!
        for _ in 0..<ticks { sync() }
        let i = onScreen.indexOfItem(withTitle: title)
        precondition(i >= 0, "no item \(title) in the open menu")
        onScreen.performActionForItem(at: i)
    }
    var shown: String { popup.titleOfSelectedItem ?? "-" }
}

@main
struct PopupMenuTests {
    static func main() {
        _ = NSApplication.shared
        print("Pen feel dropdown (PopupMenuSync) tests:")
        let lines = PenFeel(gamma: 1.5, floor: 0.0, fullAt: 1.0)

        // --- THE REGRESSION: a pick made after a refresh tick is kept -------
        for p in PenFeelCore.presets where p.name != "Normal" {
            for ticks in [0, 1, 3] {
                let w = FeelWindow()
                w.pick(p.name, ticksWhileOpen: ticks)
                expect(w.feel == p.feel && w.shown == p.name,
                       "pick: \(p.name) with \(ticks) refresh tick(s) while open is applied and shown (shows \(w.shown))")
            }
        }
        do {
            let w = FeelWindow()
            w.profiles = [PenProfile(name: "Lines", feel: lines)]
            w.sync()
            w.pick("Lines", ticksWhileOpen: 2)
            expect(w.feel == lines && w.shown == "Lines" && w.selectedProfile == "Lines",
                   "pick: a saved profile picked after refresh ticks is applied and shown")
        }
        do {
            // From Custom (no "Custom" in the menu once a preset matches).
            let w = FeelWindow()
            w.feel = PenFeel(gamma: 1.1, floor: 0.1, fullAt: 0.7); w.sync()
            expect(w.shown == "Custom", "pick: odd slider values show Custom")
            w.pick("Inking", ticksWhileOpen: 2)
            expect(w.shown == "Inking" && popupEntries(w.popup).allSatisfy { $0.title != "Custom" },
                   "pick: from Custom to a preset after ticks; Custom leaves the menu")
        }

        // --- a refresh with nothing new leaves the menu alone ---------------
        // Identity, not equality: the user is holding THESE NSMenuItems.
        do {
            let w = FeelWindow()
            w.profiles = [PenProfile(name: "Lines", feel: lines)]; w.selectedProfile = "Lines"
            w.feel = PenFeel(gamma: 1.1, floor: 0.1, fullAt: 0.7)
            w.sync()
            let menu = w.popup.menu!, items = menu.items
            for _ in 0..<5 { w.sync() }
            expect(w.popup.menu === menu, "tick: the same NSMenu object survives five refreshes")
            expect(zip(items, w.popup.menu!.items).allSatisfy { $0 === $1 } && items.count == w.popup.menu!.items.count,
                   "tick: every NSMenuItem survives five refreshes")
        }

        // --- but a real change does reach the menu --------------------------
        do {
            let w = FeelWindow()
            let before = w.popup.menu!
            w.feel = PenFeel(gamma: 1.1, floor: 0.1, fullAt: 0.7); w.sync()
            expect(w.popup.menu !== before && w.shown == "Custom", "change: moving off a preset adds Custom and selects it")
            w.profiles = [PenProfile(name: "Mine", feel: w.feel)]; w.sync()
            expect(w.shown == "Mine" && popupEntries(w.popup).contains { $0.title == "Save changes to \"Mine\"" },
                   "change: a new profile appears, is selected, and gets its commands")
            w.feel = PenFeel(gamma: 1.2, floor: 0.1, fullAt: 0.7); w.sync()
            expect(popupEntries(w.popup).first { $0.tag == Tag.update }?.enabled == true,
                   "change: Save changes becomes enabled once the sliders move off the profile")
        }

        // --- invariant sweep: what is on screen is exactly the entries ------
        // Every combination of feel, profile count and selected profile: the
        // popup shows the entries it was given (so the comparison that decides
        // "rebuild or not" can never see a difference that is not there and
        // rebuild on every tick), a second sync never rebuilds, and the
        // selected item is the one the core asked for.
        let feels = PenFeelCore.presets.map(\.feel) + [lines, PenFeel(gamma: 0.6, floor: 0.2, fullAt: 0.6)]
        let pool = [PenProfile(name: "Lines", feel: lines),
                    PenProfile(name: "Wash", feel: PenFeel(gamma: 0.7, floor: 0.0, fullAt: 0.8)),
                    PenProfile(name: "Third", feel: PenFeel(gamma: 2.0, floor: 0.1, fullAt: 0.9))]
        var sweepOK = true, stableOK = true, selOK = true, n = 0
        for feel in feels {
            for count in 0...pool.count {
                let profiles = Array(pool.prefix(count))
                for sel in [nil] + profiles.map(\.name) as [String?] {
                    let w = FeelWindow()
                    w.feel = feel; w.profiles = profiles; w.selectedProfile = sel
                    w.sync()
                    let want = PenFeelCore.menu(for: feel, profiles: profiles, selectedProfile: w.selectedProfile)
                    if popupEntries(w.popup) != want.entries { sweepOK = false }
                    if w.popup.selectedItem?.tag != want.selected { selOK = false }
                    let menu = w.popup.menu
                    w.sync()
                    if w.popup.menu !== menu { stableOK = false }
                    n += 1
                }
            }
        }
        expect(sweepOK, "sweep: the popup shows exactly the core's entries (\(n) states)")
        expect(selOK, "sweep: the popup selects exactly the core's tag (\(n) states)")
        expect(stableOK, "sweep: a second sync with nothing new never rebuilds (\(n) states)")

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("All pen feel dropdown tests passed.")
    }
}

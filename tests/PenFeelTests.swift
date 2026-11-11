// PenFeelTests.swift — the pen feel presets and the user's three custom
// profiles (PenFeelCore): adding, renaming, saving changes, deleting, and the
// file they live in.

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

@main
struct PenFeelTests {
    static func main() {
        print("PenFeelCore tests:")
        let soft = PenFeel(gamma: 0.8, floor: 0.04, fullAt: 0.9)
        let firm = PenFeel(gamma: 1.5, floor: 0.0, fullAt: 1.0)

        // --- presets -------------------------------------------------------
        let P = PenFeelCore.presets
        expect(P.first?.name == "Normal" && P.first?.feel == .normal, "presets: Normal comes first and changes nothing")
        expect(Set(P.map { $0.name.lowercased() }).count == P.count, "presets: names are unique")
        expect(P.allSatisfy { $0.feel.clamped() == $0.feel }, "presets: every preset is inside what the sliders can show")
        expect(P.allSatisfy { $0.feel.floor < $0.feel.fullAt - 0.2 }, "presets: every preset leaves room between its ends")
        for p in P {
            expect(!p.hint.contains("\u{2014}") && !p.name.contains("\u{2014}"), "presets: no dash in \(p.name)")
        }

        // --- clamped -------------------------------------------------------
        let c = PenFeel(gamma: 9, floor: -1, fullAt: 3).clamped()
        expect(c == PenFeel(gamma: 2.5, floor: 0, fullAt: 1), "clamp: values are held inside the slider ranges")
        expect(PenFeel(gamma: 0.0, floor: 0, fullAt: 1).clamped().gamma == 0.0
               && PenFeel(gamma: 0.2, floor: 0, fullAt: 1).clamped().gamma == 0.2,
               "clamp: a curve below the old 0.4 limit, down to 0, is kept")
        expect(PenFeel(gamma: -0.3, floor: 0, fullAt: 1).clamped().gamma == 0.0, "clamp: a negative curve becomes 0")
        let low = PenFeelCore.adding([], name: "Featherlight", feel: PenFeel(gamma: 0.15, floor: 0, fullAt: 1))!
        expect(PenFeelCore.parse(PenFeelCore.serialize(low)) == low, "file: a profile with a very low curve survives saving")
        expect(PenFeel(gamma: .nan, floor: .infinity, fullAt: -.infinity).clamped().gamma == 1.0,
               "clamp: NaN and infinity do not get through")
        // THE TRAP: a floor that meets fullAt would make the pen draw nothing.
        var worst = true
        for f in stride(from: -0.5, through: 1.5, by: 0.05) {
            for t in stride(from: -0.5, through: 1.5, by: 0.05) {
                let k = PenFeel(gamma: 1.3, floor: f, fullAt: t).clamped()
                if !(k.floor < k.fullAt) { worst = false }
            }
        }
        expect(worst, "clamp: whatever the numbers, the floor stays below fullAt")
        expect(soft.matches(PenFeel(gamma: 0.801, floor: 0.0401, fullAt: 0.899)), "match: slider-grain noise is the same feel")
        expect(!soft.matches(PenFeel(gamma: 0.81, floor: 0.04, fullAt: 0.9)), "match: one slider step apart is a different feel")

        // --- create ----------------------------------------------------------
        var list: [PenProfile] = []
        guard let a = PenFeelCore.adding(list, name: "  Sketch  ", feel: soft) else {
            expect(false, "create: a first profile is added"); exit(1)
        }
        list = a
        expect(list.count == 1 && list[0].name == "Sketch" && list[0].feel == soft, "create: added, name trimmed")
        list = PenFeelCore.adding(list, name: "Lines", feel: firm)!
        list = PenFeelCore.adding(list, name: "Paint", feel: .normal)!
        expect(list.map(\.name) == ["Sketch", "Lines", "Paint"], "create: three profiles, in the order made")
        // THE TRAP: three is the limit the user was promised.
        expect(PenFeelCore.adding(list, name: "Fourth", feel: soft) == nil, "create: a fourth profile is refused")
        let two = Array(list.prefix(2))
        expect(PenFeelCore.adding(two, name: "sketch", feel: soft) == nil, "create: a duplicate name is refused, any case")
        expect(PenFeelCore.adding(two, name: "Inking", feel: soft) == nil, "create: a preset's name is refused")
        expect(PenFeelCore.adding(two, name: "custom", feel: soft) == nil, "create: 'Custom' is reserved")
        expect(PenFeelCore.adding(two, name: "   ", feel: soft) == nil, "create: an empty name is refused")
        expect(PenFeelCore.adding(two, name: String(repeating: "x", count: 25), feel: soft) == nil,
               "create: a name over 24 characters is refused")
        expect(PenFeelCore.adding(two, name: String(repeating: "x", count: 24), feel: soft) != nil,
               "create: exactly 24 characters is fine")
        let bad = PenFeelCore.adding(two, name: "Odd", feel: PenFeel(gamma: 7, floor: 0, fullAt: 1))!
        expect(bad[2].feel.gamma == 2.5, "create: a feel is stored clamped")

        // --- rename ----------------------------------------------------------
        let r = PenFeelCore.renaming(list, from: "Lines", to: "Ink lines")
        expect(r?.map(\.name) == ["Sketch", "Ink lines", "Paint"] && r?[1].feel == firm,
               "rename: name changes, place and feel stay")
        expect(PenFeelCore.renaming(list, from: "Lines", to: "lines") != nil,
               "rename: changing only the case of its own name is allowed")
        expect(PenFeelCore.renaming(list, from: "Lines", to: "Paint") == nil, "rename: onto another profile's name is refused")
        expect(PenFeelCore.renaming(list, from: "Lines", to: "Normal") == nil, "rename: onto a preset is refused")
        expect(PenFeelCore.renaming(list, from: "Nope", to: "X") == nil, "rename: a missing profile is refused")

        // --- update ----------------------------------------------------------
        let u = PenFeelCore.updating(list, name: "Sketch", feel: firm)
        expect(u?[0].feel == firm && u?[0].name == "Sketch" && u?.count == 3, "update: the feel is overwritten in place")
        expect(PenFeelCore.updating(list, name: "Nope", feel: firm) == nil, "update: a missing profile is refused")

        // --- delete ----------------------------------------------------------
        let d = PenFeelCore.deleting(list, name: "Lines")
        expect(d.map(\.name) == ["Sketch", "Paint"], "delete: only that profile goes")
        expect(PenFeelCore.adding(d, name: "New", feel: soft)?.count == 3, "delete: frees a slot for a new one")
        expect(PenFeelCore.deleting(list, name: "Nope") == list, "delete: a missing name changes nothing")

        // --- the file ----------------------------------------------------------
        let text = PenFeelCore.serialize(list)
        expect(PenFeelCore.parse(text) == list, "file: what is saved comes back the same")
        expect(PenFeelCore.parse("") == [] && PenFeelCore.serialize([]) == "", "file: no profiles, empty file")
        let messy = "Good\t0.80\t0.04\t0.90\nbroken line\nAlso\tx\t0\t1\n\t1.0\t0\t1\nGood\t1.0\t0\t1\nTwo\t1.50\t0.00\t1.00\n"
        let m = PenFeelCore.parse(messy)
        expect(m.map(\.name) == ["Good", "Two"], "file: broken, nameless and duplicate lines are dropped, the rest survive")
        let many = (1...6).map { "P\($0)\t1.0\t0\t1" }.joined(separator: "\n")
        expect(PenFeelCore.parse(many).count == 3, "file: never more than three come back, whatever the file says")
        expect(PenFeelCore.parse("Weird\t9\t-1\t3").first?.feel == PenFeel(gamma: 2.5, floor: 0, fullAt: 1),
               "file: out-of-range numbers are clamped on the way in")
        // THE TRAP: a tab inside a name would split the line into the wrong columns.
        let tabbed = PenFeelCore.adding([], name: "A\tB", feel: soft)!
        expect(tabbed[0].name == "A B" && PenFeelCore.parse(PenFeelCore.serialize(tabbed)) == tabbed,
               "file: a tab typed in a name cannot break the file")

        // --- what the dropdown shows --------------------------------------------
        expect(PenFeelCore.matchName(.normal, profiles: list) == "Normal",
               "dropdown: a profile equal to a preset shows the preset")
        expect(PenFeelCore.matchName(firm, profiles: list) == "Lines", "dropdown: a profile's feel shows its name")
        expect(PenFeelCore.matchName(PenFeel(gamma: 1.1, floor: 0.1, fullAt: 0.7), profiles: list) == nil,
               "dropdown: anything else is Custom")
        let lightHand = P.first { $0.name == "Light hand" }!.feel
        expect(PenFeelCore.matchName(lightHand, profiles: []) == "Light hand", "dropdown: a preset shows its own name")

        // --- the dropdown's contents (PenFeelCore.menu) ---------------------
        typealias Tag = PenFeelCore.Tag
        func titles(_ e: [PenFeelCore.MenuEntry]) -> [String] { e.map { $0.isSeparator ? "-" : $0.title } }
        let odd = PenFeel(gamma: 1.1, floor: 0.1, fullAt: 0.7)
        let m0 = PenFeelCore.menu(for: .normal, profiles: [], selectedProfile: nil)
        expect(titles(m0.entries) == P.map(\.name) + ["-", "Save as profile…"],
               "menu: no profiles, on a preset: the presets, then Save as profile")
        expect(m0.selected == Tag.preset, "menu: Normal is selected by its own tag")
        expect(m0.entries.first { $0.tag == Tag.save }?.enabled == false,
               "menu: Save as profile is off while a preset is showing (nothing new to save)")
        let mC = PenFeelCore.menu(for: odd, profiles: [], selectedProfile: nil)
        expect(mC.selected == Tag.custom && titles(mC.entries).contains("Custom"),
               "menu: values matching nothing add Custom and select it")
        expect(mC.entries.first { $0.tag == Tag.save }?.enabled == true, "menu: Custom values can be saved")
        expect(!titles(m0.entries).contains("Custom"), "menu: Custom is absent while a preset matches")
        for (i, p) in P.enumerated() {
            expect(PenFeelCore.menu(for: p.feel, profiles: [], selectedProfile: nil).selected == Tag.preset + i,
                   "menu: \(p.name) selects its own tag")
        }
        let mine = [PenProfile(name: "Lines", feel: firm)]
        let mP = PenFeelCore.menu(for: firm, profiles: mine, selectedProfile: "Lines")
        expect(mP.selected == Tag.profile && titles(mP.entries).contains("Lines"),
               "menu: a profile's feel selects the profile")
        expect(mP.entries.first { $0.tag == Tag.update }?.enabled == false,
               "menu: Save changes is off while the sliders still match the profile")
        let mPmoved = PenFeelCore.menu(for: odd, profiles: mine, selectedProfile: "Lines")
        expect(mPmoved.entries.first { $0.tag == Tag.update }?.enabled == true,
               "menu: Save changes turns on once the sliders move off the profile")
        expect(titles(mPmoved.entries).suffix(3) == ["Save changes to \"Lines\"", "Rename \"Lines\"…", "Delete \"Lines\""],
               "menu: the selected profile's commands come last, named after it")
        expect(!titles(PenFeelCore.menu(for: odd, profiles: mine, selectedProfile: nil).entries).contains { $0.hasPrefix("Rename") },
               "menu: no profile selected, no profile commands")
        expect(!titles(PenFeelCore.menu(for: odd, profiles: mine, selectedProfile: "Gone").entries).contains { $0.hasPrefix("Delete") },
               "menu: a selected name that no longer exists gets no commands")
        let full = [PenProfile(name: "A", feel: soft), PenProfile(name: "B", feel: firm),
                    PenProfile(name: "C", feel: PenFeel(gamma: 2, floor: 0, fullAt: 1))]
        let save = PenFeelCore.menu(for: odd, profiles: full, selectedProfile: nil).entries.first { $0.tag == Tag.save }
        expect(save?.enabled == false && save?.tip?.contains("Delete one first") == true,
               "menu: three profiles: Save as profile is off and says why")
        // The rebuild decision compares entries: the same state must give
        // equal entries, or every 1 s refresh would rebuild the open menu.
        expect(PenFeelCore.menu(for: odd, profiles: full, selectedProfile: "B").entries
               == PenFeelCore.menu(for: odd, profiles: full, selectedProfile: "B").entries,
               "menu: the same state gives equal entries every time")
        var tagsUnique = true, noDash = true
        for f in [PenFeel.normal, firm, odd] {
            for sel in [nil, "A", "B"] as [String?] {
                let e = PenFeelCore.menu(for: f, profiles: full, selectedProfile: sel).entries.filter { !$0.isSeparator }
                if Set(e.map(\.tag)).count != e.count { tagsUnique = false }
                if e.contains(where: { $0.title.contains("\u{2014}") || ($0.tip ?? "").contains("\u{2014}") }) { noDash = false }
            }
        }
        expect(tagsUnique, "menu: no two items share a tag (feelChanged routes by tag)")
        expect(noDash, "menu: no dash in any title or tooltip")

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("All PenFeelCore tests passed.")
    }
}

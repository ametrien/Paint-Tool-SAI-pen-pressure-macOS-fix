// PenFeelCore.swift — the pen feel presets, and the user's saved profiles.
//
// A feel is three numbers (PressureCore.feel): gamma (the shape), floor
// (ignore the lightest touch), fullAt (full width at less than full force).
// Presets are fixed; up to three custom profiles are the user's own, kept in
// one small text file.
//
// No AppKit, no file access: the tests compile this file on its own. The file
// I/O is a string in and a string out (parse/serialize); Settings.swift owns
// the path.

import Foundation

struct PenFeel: Equatable {
    var gamma: Double
    var floor: Double
    var fullAt: Double

    static let normal = PenFeel(gamma: 1.0, floor: 0.0, fullAt: 1.0)

    /// Keep any stored value inside what the UI can show and the mapping can
    /// take. A floor that reached fullAt would kill the pen entirely, so the
    /// window between them is held open.
    func clamped() -> PenFeel {
        // Down to 0: below 0.4 is very soft, and 0 itself is "no pressure",
        // every touch full width. Both are real choices people make.
        var g = gamma.isFinite ? min(2.5, max(0.0, gamma)) : 1.0
        var f = floor.isFinite ? min(0.3, max(0.0, floor)) : 0.0
        var c = fullAt.isFinite ? min(1.0, max(0.5, fullAt)) : 1.0
        if f >= c { f = 0.0; c = 1.0; g = 1.0 }     // corrupt: back to Normal
        return PenFeel(gamma: g, floor: f, fullAt: c)
    }

    /// Two feels the sliders cannot tell apart are the same feel. The sliders
    /// step by 0.01, so compare at that grain, not by exact doubles.
    func matches(_ o: PenFeel) -> Bool {
        func eq(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
        return eq(gamma, o.gamma) && eq(floor, o.floor) && eq(fullAt, o.fullAt)
    }
}

/// A saved custom profile: a feel with the user's name on it.
struct PenProfile: Equatable {
    var name: String
    var feel: PenFeel
}

enum PenFeelCore {
    /// The presets, named by what people are doing rather than by stiffness.
    /// Starting points, not measured truths; the sliders remain for taste.
    static let presets: [(name: String, feel: PenFeel, hint: String)] = [
        ("Normal",     PenFeel.normal,                                "exactly what the tablet reports"),
        ("Light hand", PenFeel(gamma: 0.75, floor: 0.00, fullAt: 0.85), "full width without pressing hard · easy on the hand"),
        ("Inking",     PenFeel(gamma: 1.20, floor: 0.05, fullAt: 1.00), "ignores the lightest touch, for clean line starts"),
        ("Painting",   PenFeel(gamma: 0.90, floor: 0.02, fullAt: 0.95), "even strokes for soft blending"),
        ("Heavy hand", PenFeel(gamma: 1.35, floor: 0.03, fullAt: 1.00), "control for people who press hard"),
    ]

    static let maxProfiles = 3
    static let maxNameLength = 24

    /// nil when the name is usable; otherwise why not, in words for a dialog.
    /// `existing` are the current profiles; `renaming` is the profile being
    /// renamed, whose own name is of course allowed.
    static func nameProblem(_ raw: String, existing: [PenProfile], renaming: String? = nil) -> String? {
        let name = cleanName(raw)
        if name.isEmpty { return "The name is empty." }
        if name.count > maxNameLength { return "That name is too long. Up to \(maxNameLength) characters." }
        if presets.contains(where: { $0.name.lowercased() == name.lowercased() }) || name.lowercased() == "custom" {
            return "\"\(name)\" is already a preset. Pick another name."
        }
        if existing.contains(where: { $0.name.lowercased() == name.lowercased()
                                      && $0.name.lowercased() != renaming?.lowercased() }) {
            return "You already have a profile called \"\(name)\"."
        }
        return nil
    }

    /// What of a typed name is kept: one line, trimmed, inner whitespace kept.
    /// Tabs would break the storage format, so they become spaces BEFORE the
    /// name is judged or saved.
    static func cleanName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\t", with: " ")
           .replacingOccurrences(of: "\n", with: " ")
           .replacingOccurrences(of: "\r", with: " ")
           .trimmingCharacters(in: .whitespaces)
    }

    // ---- CRUD on the list (pure; the caller saves the result) --------------

    /// Add a profile. nil = refused (bad name, or the list is full).
    static func adding(_ list: [PenProfile], name: String, feel: PenFeel) -> [PenProfile]? {
        guard list.count < maxProfiles, nameProblem(name, existing: list) == nil else { return nil }
        return list + [PenProfile(name: cleanName(name), feel: feel.clamped())]
    }

    /// Overwrite the named profile's feel. nil = no such profile.
    static func updating(_ list: [PenProfile], name: String, feel: PenFeel) -> [PenProfile]? {
        guard let i = list.firstIndex(where: { $0.name == name }) else { return nil }
        var out = list
        out[i].feel = feel.clamped()
        return out
    }

    /// Rename a profile, keeping its place. nil = refused.
    static func renaming(_ list: [PenProfile], from: String, to: String) -> [PenProfile]? {
        guard let i = list.firstIndex(where: { $0.name == from }),
              nameProblem(to, existing: list, renaming: from) == nil else { return nil }
        var out = list
        out[i].name = cleanName(to)
        return out
    }

    static func deleting(_ list: [PenProfile], name: String) -> [PenProfile] {
        list.filter { $0.name != name }
    }

    // ---- the file (one line per profile: name TAB gamma TAB floor TAB fullAt)

    static func serialize(_ list: [PenProfile]) -> String {
        list.map { p in
            let f = p.feel.clamped()
            return "\(p.name)\t\(String(format: "%.2f", f.gamma))\t\(String(format: "%.2f", f.floor))\t\(String(format: "%.2f", f.fullAt))"
        }.joined(separator: "\n") + (list.isEmpty ? "" : "\n")
    }

    /// A line that does not parse is dropped, not guessed at; the lines around
    /// it survive. Whatever the file says, no more than maxProfiles come back.
    static func parse(_ text: String) -> [PenProfile] {
        var out: [PenProfile] = []
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 4,
                  let g = Double(cols[1]), let f = Double(cols[2]), let c = Double(cols[3]) else { continue }
            let name = cleanName(String(cols[0]))
            guard !name.isEmpty, name.count <= maxNameLength,
                  !out.contains(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
            out.append(PenProfile(name: name, feel: PenFeel(gamma: g, floor: f, fullAt: c).clamped()))
            if out.count == maxProfiles { break }
        }
        return out
    }

    /// What the dropdown should select for the current slider values: a preset
    /// name, a profile name (presets win, so "Normal" never shows as a copy of
    /// itself), or nil = Custom.
    static func matchName(_ feel: PenFeel, profiles: [PenProfile]) -> String? {
        if let p = presets.first(where: { $0.feel.matches(feel) }) { return p.name }
        return profiles.first(where: { $0.feel.matches(feel) })?.name
    }

    // ---- the dropdown's contents (pure; PopupMenuSync.swift puts them on screen)

    /// Tags for the feel popup's items. Presets and profiles select a feel;
    /// the last group are commands that run and then put the selection back.
    enum Tag {
        static let preset = 100, profile = 200, custom = 300
        static let save = 401, update = 402, rename = 403, delete = 404
    }

    /// One line of the dropdown, as plain data, so two states of the window can
    /// be compared and the tests can read the menu without AppKit.
    struct MenuEntry: Equatable {
        var title: String
        var tag: Int
        var enabled = true
        var tip: String? = nil
        var isSeparator = false
        static let separator = MenuEntry(title: "", tag: 0, isSeparator: true)
    }

    /// Everything the dropdown shows for this moment, and the tag to select.
    /// `selectedProfile` is the custom profile last picked, kept while the
    /// sliders move away from it, so "Save changes to X" knows which one.
    static func menu(for feel: PenFeel, profiles: [PenProfile],
                     selectedProfile: String?) -> (entries: [MenuEntry], selected: Int) {
        let match = matchName(feel, profiles: profiles)
        var e: [MenuEntry] = []
        for (n, p) in presets.enumerated() {
            e.append(MenuEntry(title: p.name, tag: Tag.preset + n, tip: p.hint))
        }
        if !profiles.isEmpty {
            e.append(.separator)
            for (n, p) in profiles.enumerated() { e.append(MenuEntry(title: p.name, tag: Tag.profile + n)) }
        }
        if match == nil { e.append(.separator); e.append(MenuEntry(title: "Custom", tag: Tag.custom)) }
        e.append(.separator)
        let room = profiles.count < maxProfiles
        e.append(MenuEntry(title: "Save as profile…", tag: Tag.save, enabled: room && match == nil,
                           tip: room ? nil : "All \(maxProfiles) profile slots are used. Delete one first."))
        if let sel = selectedProfile, let p = profiles.first(where: { $0.name == sel }) {
            e.append(MenuEntry(title: "Save changes to \"\(sel)\"", tag: Tag.update, enabled: !p.feel.matches(feel)))
            e.append(MenuEntry(title: "Rename \"\(sel)\"…", tag: Tag.rename))
            e.append(MenuEntry(title: "Delete \"\(sel)\"", tag: Tag.delete))
        }
        // Presets win over profiles (matchName), and a profile can never carry
        // a preset's name (nameProblem), so the name finds exactly one item.
        var selected = Tag.custom
        if let m = match {
            if let i = presets.firstIndex(where: { $0.name == m }) { selected = Tag.preset + i }
            else if let i = profiles.firstIndex(where: { $0.name == m }) { selected = Tag.profile + i }
        }
        return (e, selected)
    }
}

// KeysCore.swift — what each Mac modifier key sends to SAI, as pure data.
//
// Wine's Mac driver has exactly four switches for this, read once when Wine
// starts, all OFF by default:
//
//   LeftOptionIsAlt / RightOptionIsAlt     Option -> Alt
//   LeftCommandIsCtrl / RightCommandIsCtrl Command -> Ctrl
//
// With a switch off, Wine's own defaults apply: Command is sent as Alt, and
// Option stays Option, i.e. it is used with the Mac keyboard layout to type
// characters (@ is Option+L on a German Mac, € is Option+E or Option+2 on
// several others) and Windows never sees it as Alt.
//
// THE TRAP this file exists for (issue #36): the app has always turned both
// Command switches on, so ⌘Z is Ctrl+Z. That took away the only key Wine sends
// as Alt, and nothing replaced it — so no key on the Mac produced Alt at all,
// and Alt is SAI's eyedropper. The default below makes BOTH Option keys Alt:
// drawing needs Alt far more often than SAI needs a typed @ or €. The cost is
// real on layouts that type characters with Option, so the Keys tab says how
// to give one Option key back to typing.
//
// No AppKit here: the tests compile this file on its own.

import Foundation

enum MacModifierKey: String, CaseIterable {
    case leftOption, rightOption, leftCommand, rightCommand

    /// The Wine registry value under HKCU\Software\Wine\Mac Driver.
    var wineValueName: String {
        switch self {
        case .leftOption:   return "LeftOptionIsAlt"
        case .rightOption:  return "RightOptionIsAlt"
        case .leftCommand:  return "LeftCommandIsCtrl"
        case .rightCommand: return "RightCommandIsCtrl"
        }
    }

    var label: String {
        switch self {
        case .leftOption:   return "Left ⌥ Option"
        case .rightOption:  return "Right ⌥ Option"
        case .leftCommand:  return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        }
    }

    var isOption: Bool { self == .leftOption || self == .rightOption }

    /// What the key sends with its Wine switch on, and with it off.
    /// Off is Wine's own behaviour, not something this app chose.
    var whenOn: KeyRole { isOption ? .alt : .ctrl }
    var whenOff: KeyRole { isOption ? .typing : .alt }
}

/// What SAI receives when the key is held.
enum KeyRole: String {
    case ctrl, alt, typing

    var label: String {
        switch self {
        case .ctrl:   return "Ctrl"
        case .alt:    return "Alt"
        case .typing: return "Option (types special characters)"
        }
    }
}

struct KeyMapping: Equatable {
    /// Whether each key's Wine switch is on.
    var on: [MacModifierKey: Bool]

    /// ⌘ → Ctrl on both sides (what the app has always done), ⌥ → Alt on both.
    static let defaults = KeyMapping(on: [
        .leftOption: true, .rightOption: true,
        .leftCommand: true, .rightCommand: true,
    ])

    func role(_ k: MacModifierKey) -> KeyRole {
        (on[k] ?? KeyMapping.defaults.on[k]!) ? k.whenOn : k.whenOff
    }

    mutating func set(_ k: MacModifierKey, to role: KeyRole) {
        on[k] = (role == k.whenOn)
    }

    /// The four registry values, in a fixed order. ALL four are always written,
    /// "N" included: a key switched back off has to be turned off in Wine too,
    /// not merely left out.
    var wineValues: [(name: String, value: String)] {
        MacModifierKey.allCases.map { ($0.wineValueName, role($0) == $0.whenOn ? "Y" : "N") }
    }

    /// Does any key send Alt? If not, SAI's Alt shortcuts are unreachable.
    var hasAlt: Bool { MacModifierKey.allCases.contains { role($0) == .alt } }

    /// Can special characters still be typed with some Option key?
    var canTypeSpecialCharacters: Bool {
        role(.leftOption) == .typing || role(.rightOption) == .typing
    }

    // MARK: - the settings file
    //
    // One "key=on|off" line each, e.g. "leftOption=on". Unknown lines are
    // ignored and missing keys take the default, so an older or hand-edited
    // file never breaks anything.

    static func parse(_ text: String) -> KeyMapping {
        var m = KeyMapping.defaults
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let k = MacModifierKey(rawValue: parts[0]) else { continue }
            switch parts[1].lowercased() {
            case "on", "y", "yes", "1", "true": m.on[k] = true
            case "off", "n", "no", "0", "false": m.on[k] = false
            default: continue
            }
        }
        return m
    }

    var serialized: String {
        MacModifierKey.allCases.map { "\($0.rawValue)=\(role($0) == $0.whenOn ? "on" : "off")" }
            .joined(separator: "\n") + "\n"
    }

    /// One line for the problem report: what each key is set to send.
    var summary: String {
        MacModifierKey.allCases.map { k -> String in
            let short = k.label.replacingOccurrences(of: " Option", with: "")
                .replacingOccurrences(of: " Command", with: "")
            let r = role(k) == .typing ? "typing" : role(k).label
            return "\(short)→\(r)"
        }.joined(separator: ", ")
    }

    // MARK: - reading back what Wine actually has

    /// The Mac Driver values as they stand in a prefix's user.reg, by name.
    /// Used by the health check, so it reports what Wine will read rather than
    /// what this app believes it wrote.
    static func wineValues(inUserReg reg: String) -> [String: String] {
        var out: [String: String] = [:]
        var inSection = false
        for raw in reg.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // user.reg doubles every backslash in a key name.
                inSection = line.lowercased().hasPrefix("[software\\\\wine\\\\mac driver]")
                continue
            }
            guard inSection, line.hasPrefix("\"") else { continue }
            // "LeftOptionIsAlt"="Y"
            let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            out[name] = value
        }
        return out
    }

    /// Names of the values whose state in Wine differs from this mapping. A
    /// missing value counts as "N", because that is how Wine reads it.
    func mismatches(againstUserReg reg: String) -> [String] {
        let have = KeyMapping.wineValues(inUserReg: reg)
        return wineValues.compactMap { want in
            let got = (have[want.name] ?? "N").uppercased().hasPrefix("Y") ? "Y" : "N"
            return got == want.value ? nil : want.name
        }
    }
}

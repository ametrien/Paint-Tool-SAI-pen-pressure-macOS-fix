// LibrarySelection.swift: which videos are selected in the Videos tab, and the
// words the bulk delete uses. Pure, so tests/LibrarySelectionTests.swift runs it
// without a window.
//
// Clicks follow Finder: a click selects one, ⌘-click adds or removes one,
// Shift-click adds everything between the last click and this one.

import Foundation

struct LibrarySelection: Equatable {
    enum Modifier { case none, toggle, range }

    private(set) var keys: Set<String> = []
    /// Where a Shift-click range starts: the last plain or ⌘ click.
    private(set) var anchor: String?

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }
    func contains(_ key: String) -> Bool { keys.contains(key) }

    /// `order` is the grid's order, top left to bottom right.
    mutating func click(_ key: String, modifier: Modifier, order: [String]) {
        switch modifier {
        case .none:
            keys = [key]
            anchor = key
        case .toggle:
            if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
            anchor = key
        case .range:
            guard let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: key) else {
                keys = [key]; anchor = key; return
            }
            keys.formUnion(order[min(i, j)...max(i, j)])
            // The anchor stays put, so a second Shift-click grows or moves the
            // range from the same place, as in Finder.
        }
    }

    /// A right-click on something outside the selection selects just that, so
    /// the menu never acts on things the pointer is not on.
    mutating func rightClick(_ key: String) {
        if !keys.contains(key) { keys = [key]; anchor = key }
    }

    mutating func selectAll(_ order: [String]) {
        keys = Set(order)
        anchor = order.first
    }

    mutating func clear() {
        keys = []
        anchor = nil
    }

    /// After the list is rebuilt: forget what is no longer there, so a deleted
    /// video cannot stay "selected" and be deleted a second time.
    mutating func keep(only order: [String]) {
        keys.formIntersection(order)
        if let a = anchor, !order.contains(a) { anchor = nil }
    }

    /// The selected keys in grid order.
    func ordered(_ order: [String]) -> [String] { order.filter { keys.contains($0) } }

    // MARK: keys

    static func drawingKey(_ id: String) -> String { "d:" + id }
    static func fileKey(_ path: String) -> String { "f:" + path }
    static func drawingId(_ key: String) -> String? { key.hasPrefix("d:") ? String(key.dropFirst(2)) : nil }
    static func filePath(_ key: String) -> String? { key.hasPrefix("f:") ? String(key.dropFirst(2)) : nil }

    // MARK: words

    static func counted(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// The bottom bar: what the selection is, or how to make one.
    static func status(selected n: Int) -> String {
        n == 0 ? "Click to select. ⌘ or Shift adds more." : "\(n) selected"
    }

    /// Title of the delete question. One item is named; several are counted.
    static func deleteTitle(names: [String]) -> String {
        names.count == 1 ? "Delete “\(names[0])”?" : "Delete \(names.count) videos?"
    }

    /// What exactly goes, in words, for the delete question.
    static func deleteDetail(drawings: Int, sessions: Int, older: Int) -> String {
        var parts: [String] = []
        if drawings > 0 {
            parts.append(drawings == 1
                ? "the recording of 1 drawing (\(counted(sessions, "session")))"
                : "the recordings of \(drawings) drawings (\(counted(sessions, "session")))")
        }
        if older > 0 { parts.append(counted(older, "older video")) }
        return "This moves " + parts.joined(separator: " and ") + " to the Trash. Your artwork is untouched."
    }
}

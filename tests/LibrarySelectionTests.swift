// LibrarySelectionTests.swift: selecting videos in the Videos tab, and the words
// the bulk delete uses (LibrarySelection.swift).

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

@main
struct LibrarySelectionTests {
    static func main() {
        print("LibrarySelection tests:")
        let order = ["a", "b", "c", "d", "e"]
        var s = LibrarySelection()

        s.click("b", modifier: .none, order: order)
        expect(s.keys == ["b"], "click: selects just that one")
        s.click("d", modifier: .none, order: order)
        expect(s.keys == ["d"], "click: another click moves the selection")

        s.click("a", modifier: .toggle, order: order)
        expect(s.keys == ["a", "d"], "⌘-click: adds one")
        s.click("d", modifier: .toggle, order: order)
        expect(s.keys == ["a"], "⌘-click: on a selected one removes it")

        s.click("b", modifier: .none, order: order)
        s.click("d", modifier: .range, order: order)
        expect(s.keys == ["b", "c", "d"], "Shift-click: selects everything between")
        s.click("a", modifier: .range, order: order)
        expect(s.keys == ["a", "b", "c", "d"], "Shift-click: the range grows from the same start")
        expect(s.ordered(order) == ["a", "b", "c", "d"], "ordered: in grid order")

        var r = LibrarySelection()
        r.click("c", modifier: .range, order: order)
        expect(r.keys == ["c"], "Shift-click with nothing selected selects just that one")

        // TRAP: a right-click on an unselected video while others are selected
        // must not open a menu that deletes the others.
        var m = LibrarySelection()
        m.click("a", modifier: .none, order: order)
        m.click("b", modifier: .toggle, order: order)
        m.rightClick("e")
        expect(m.keys == ["e"], "right-click: outside the selection selects only that one")
        m.click("a", modifier: .toggle, order: order)
        m.rightClick("a")
        expect(m.keys == ["a", "e"], "right-click: inside the selection keeps it")

        s.selectAll(order)
        expect(s.count == 5, "select all")
        // TRAP: after a delete the list is rebuilt. A key left behind would stay
        // "selected" while invisible, and the next Delete would include it.
        s.keep(only: ["a", "c"])
        expect(s.keys == ["a", "c"], "keep: what is gone is no longer selected")
        s.clear()
        expect(s.isEmpty && s.anchor == nil, "clear")

        // --- keys ----------------------------------------------------------
        expect(LibrarySelection.drawingId(LibrarySelection.drawingKey("x1")) == "x1"
               && LibrarySelection.filePath(LibrarySelection.drawingKey("x1")) == nil, "keys: a drawing")
        expect(LibrarySelection.filePath(LibrarySelection.fileKey("/v/a b.mp4")) == "/v/a b.mp4"
               && LibrarySelection.drawingId(LibrarySelection.fileKey("/v/a.mp4")) == nil, "keys: a file")

        // --- words ---------------------------------------------------------
        expect(LibrarySelection.status(selected: 0) == "Click to select. ⌘ or Shift adds more."
               && LibrarySelection.status(selected: 3) == "3 selected", "status line")
        expect(LibrarySelection.deleteTitle(names: ["NewCanvas1"]) == "Delete “NewCanvas1”?"
               && LibrarySelection.deleteTitle(names: ["a", "b"]) == "Delete 2 videos?", "delete title")
        expect(LibrarySelection.deleteDetail(drawings: 1, sessions: 1, older: 0)
               == "This moves the recording of 1 drawing (1 session) to the Trash. Your artwork is untouched.",
               "delete detail: one drawing")
        expect(LibrarySelection.deleteDetail(drawings: 3, sessions: 5, older: 2)
               == "This moves the recordings of 3 drawings (5 sessions) and 2 older videos to the Trash. Your artwork is untouched.",
               "delete detail: several of both")
        for t in [LibrarySelection.deleteDetail(drawings: 2, sessions: 2, older: 1), LibrarySelection.status(selected: 0)] {
            expect(!t.contains("\u{2014}") && !t.contains("\u{2013}") && !t.contains("(s)"),
                   "words: no dash and no (s) in \"\(t)\"")
        }

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("All LibrarySelection tests passed.")
    }
}

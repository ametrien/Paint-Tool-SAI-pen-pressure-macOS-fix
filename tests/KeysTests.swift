// KeysTests.swift — unit tests for KeysCore (what each Mac modifier sends to SAI).

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String,
            file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

@main
struct KeysTests {
    static func main() {
        print("KeysCore tests:")

        // --- defaults: the issue #36 fix --------------------------------------
        let d = KeyMapping.defaults
        expect(d.role(.leftCommand) == .ctrl && d.role(.rightCommand) == .ctrl,
               "defaults: ⌘ is still Ctrl on both sides (⌘Z, ⌘S keep working)")
        expect(d.role(.leftOption) == .alt && d.role(.rightOption) == .alt,
               "defaults: both ⌥ are Alt — the eyedropper works out of the box, either hand")
        expect(d.hasAlt, "defaults: some key sends Alt")
        expect(!d.canTypeSpecialCharacters, "defaults: ⌥ characters need one Option key set back (the tab says how)")

        // THE TRAP: the mapping the app shipped before #36 — no key sends Alt.
        var old = d; old.set(.leftOption, to: .typing); old.set(.rightOption, to: .typing)
        expect(!old.hasAlt, "pre-#36 mapping (⌘→Ctrl, ⌥ untouched) is recognised as having no Alt")

        // --- registry values: all four, always --------------------------------
        let v = Dictionary(uniqueKeysWithValues: d.wineValues.map { ($0.name, $0.value) })
        expect(v.count == 4, "wine: all four values are written, not only the ones switched on")
        expect(v["LeftOptionIsAlt"] == "Y" && v["RightOptionIsAlt"] == "Y", "wine: both ⌥ Y")
        var typingRight = d; typingRight.set(.rightOption, to: .typing)
        expect(typingRight.wineValues.first { $0.name == "RightOptionIsAlt" }?.value == "N",
               "wine: right ⌥ set back to typing writes N, so switching back off sticks")
        expect(typingRight.canTypeSpecialCharacters, "one ⌥ set to typing gives special characters back")
        expect(v["LeftCommandIsCtrl"] == "Y" && v["RightCommandIsCtrl"] == "Y", "wine: ⌘ → Ctrl both sides")

        var cmdAlt = d; cmdAlt.set(.leftCommand, to: .alt)
        expect(cmdAlt.wineValues.first { $0.name == "LeftCommandIsCtrl" }?.value == "N",
               "wine: ⌘ set to Alt means LeftCommandIsCtrl=N (Wine's own default sends ⌘ as Alt)")

        let both = d

        // --- settings file ----------------------------------------------------
        expect(KeyMapping.parse("") == d, "file: empty means defaults")
        expect(KeyMapping.parse("garbage\nleftOption=maybe\n") == d, "file: junk lines are ignored")
        let custom = KeyMapping.parse("rightOption=off\nleftCommand=off\n")
        expect(custom.role(.rightOption) == .typing && custom.role(.leftCommand) == .alt
               && custom.role(.leftOption) == .alt, "file: listed keys change, missing keys keep defaults")
        expect(KeyMapping.parse(custom.serialized) == custom, "file: round-trips")

        // --- reading Wine's user.reg back -------------------------------------
        let reg = """
        WINE REGISTRY Version 2

        [Software\\\\Wine\\\\DllOverrides] 1730000000
        "wintab32"="native,builtin"

        [Software\\\\Wine\\\\Mac Driver] 1730000000
        #time=1db
        "LeftCommandIsCtrl"="Y"
        "RightCommandIsCtrl"="Y"

        [Software\\\\Wine\\\\X11 Driver] 1730000000
        "LeftOptionIsAlt"="Y"
        """
        let got = KeyMapping.wineValues(inUserReg: reg)
        expect(got["LeftCommandIsCtrl"] == "Y" && got["LeftOptionIsAlt"] == nil,
               "user.reg: reads only the Mac Driver section (a same-named value elsewhere is not it)")
        expect(d.mismatches(againstUserReg: reg) == ["LeftOptionIsAlt", "RightOptionIsAlt"],
               "user.reg: an old prefix is reported as missing ⌥ → Alt")
        expect(old.mismatches(againstUserReg: reg).isEmpty,
               "user.reg: a missing value counts as N, the way Wine reads it")

        // What the reporter of #36 pasted: the fix by hand.
        let fixed = reg.replacingOccurrences(of: "\"RightCommandIsCtrl\"=\"Y\"",
            with: "\"RightCommandIsCtrl\"=\"Y\"\n\"LeftOptionIsAlt\"=\"Y\"\n\"RightOptionIsAlt\"=\"Y\"")
        expect(both.mismatches(againstUserReg: fixed).isEmpty,
               "user.reg: the hand edit from #36 reads as both ⌥ keys → Alt")

        expect(d.summary == "Left ⌥→Alt, Right ⌥→Alt, Left ⌘→Ctrl, Right ⌘→Ctrl",
               "summary: one readable line for the problem report (\(d.summary))")

        print(failures == 0 ? "All KeysCore tests passed." : "\(failures) KeysCore test(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

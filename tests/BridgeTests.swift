// BridgeTests.swift — unit tests for BridgeCheck (is the bridge alive inside
// SAI?). Same shape as CoreTests.swift: no XCTest, no SPM, just swiftc.
//
// Run:  bash tests/run-tests.sh
//
// These cases are written from the field report that caused the module (#29):
// a prefix whose DLL file is present and correct while the registry sends Wine
// to its own built-in one. Every check the app had passed; this is the one that
// wouldn't have.

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String,
            file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

// A real prefix's user.reg, trimmed to the parts that matter.
let regWithOverride = """
WINE REGISTRY Version 2
;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

#arch=win64

[Software\\\\Wine\\\\Mac Driver] 1757000000
#time=1dc0000000
"LeftCommandIsCtrl"="Y"

[Software\\\\Wine\\\\DllOverrides] 1757000001
#time=1dc0000001
"wintab32"="native,builtin"
"""

let regWithoutOverride = """
WINE REGISTRY Version 2

[Software\\\\Wine\\\\Mac Driver] 1757000000
"LeftCommandIsCtrl"="Y"

[Software\\\\Wine\\\\DllOverrides] 1757000001
"*d3d11"="disabled"
"""

@main
struct BridgeTests {
    static func main() {

        print("BridgeCheck tests:")

        // --- the registry override ------------------------------------------
        expect(BridgeCheck.overrideValue(inUserReg: regWithOverride) == "native,builtin",
               "reg: finds the override in the DllOverrides section")
        expect(BridgeCheck.overrideValue(inUserReg: regWithoutOverride) == nil,
               "reg: section present but no wintab32 key -> nil")
        expect(BridgeCheck.overrideValue(inUserReg: "") == nil,
               "reg: empty file -> nil")

        // winecfg's spelling of the same thing
        let star = regWithOverride.replacingOccurrences(of: "\"wintab32\"", with: "\"*wintab32\"")
        expect(BridgeCheck.overrideValue(inUserReg: star) == "native,builtin",
               "reg: *wintab32 (winecfg's spelling) counts too")

        // A key of the same name in a DIFFERENT section must not be mistaken
        // for the override — that would report a broken prefix as healthy.
        let elsewhere = """
        [Software\\\\Wine\\\\AppDefaults\\\\other.exe] 1
        "wintab32"="native,builtin"
        """
        expect(BridgeCheck.overrideValue(inUserReg: elsewhere) == nil,
               "reg: same key in another section is not the override")

        // --- the same question asked of wine itself ---------------------------
        // Needed because user.reg lags every write by seconds (and by a whole
        // SAI session while wineserver is up), so a repair verified against the
        // FILE reports failure while the key is in fact correct. `reg query`
        // reads wineserver's live registry. Real output, CRLF and all — the
        // line endings are part of the fixture on purpose: splitting on "\n"
        // alone leaves a trailing \r on every value and "native,builtin\r"
        // matches nothing.
        let q = "\r\nHKEY_CURRENT_USER\\Software\\Wine\\DllOverrides\r\n"
              + "    wintab32    REG_SZ    native,builtin\r\n\r\n"
        expect(BridgeCheck.overrideValue(inRegQuery: q) == "native,builtin",
               "query: reads the value out of real reg query output")
        expect(BridgeCheck.overrideValue(inRegQuery:
                 q.replacingOccurrences(of: "    wintab32 ", with: "    *wintab32 ")) == "native,builtin",
               "query: *wintab32 spelling counts here too")
        expect(BridgeCheck.overrideValue(inRegQuery: "") == nil,
               "query: no such key (empty output) -> nil")
        // The #29 value has to survive the round trip as itself, or the repair
        // check cannot tell a broken prefix from a fixed one.
        expect(BridgeCheck.overrideValue(inRegQuery:
                 q.replacingOccurrences(of: "native,builtin", with: "builtin,native")) == "builtin,native",
               "query: builtin-first is read back verbatim, not normalised")
        // The trap: a NEIGHBOURING override whose value happens to name ours.
        // Matching "the line mentions wintab32" would answer for that row and
        // call an unset override healthy — the exact failure #29 was.
        let neighbour = "\r\nHKEY_CURRENT_USER\\Software\\Wine\\DllOverrides\r\n"
                      + "    d3d11    REG_SZ    wintab32,builtin\r\n\r\n"
        expect(BridgeCheck.overrideValue(inRegQuery: neighbour) == nil,
               "query: another key whose VALUE mentions wintab32 is not ours")

        // --- what the value means -------------------------------------------
        expect(BridgeCheck.overrideIsNative("native,builtin"), "value: native,builtin -> ours loads")
        expect(BridgeCheck.overrideIsNative("native"),         "value: native alone -> ours loads")
        expect(BridgeCheck.overrideIsNative(" Native , builtin "), "value: spacing and case don't matter")
        // The order IS the meaning: builtin first means Wine never reaches ours.
        expect(!BridgeCheck.overrideIsNative("builtin,native"), "value: builtin first -> ours is ignored")
        expect(!BridgeCheck.overrideIsNative("disabled"), "value: disabled -> no")
        expect(!BridgeCheck.overrideIsNative(nil), "value: missing key -> no")

        // --- the status file --------------------------------------------------
        let live = """
        v=1
        build=Sep 10 2026 18:07:11
        open=1
        recv=1234
        posted=1200
        fetched=1198
        pmax=4095
        """
        let s = BridgeCheck.parseStatus(live)
        expect(s != nil, "status: parses")
        expect(s?.build == "Sep 10 2026 18:07:11", "status: build stamp keeps its spaces")
        expect(s?.open == true && s?.recv == 1234 && s?.posted == 1200 && s?.fetched == 1198 && s?.pmax == 4095,
               "status: fields")
        expect(BridgeCheck.parseStatus("open=1\nrecv=5") == nil,
               "status: no version marker -> not our file")
        expect(BridgeCheck.parseStatus("v=2\nopen=1\nrecv=5\nnewfield=x")?.recv == 5,
               "status: a newer DLL's extra keys are ignored, not fatal")

        // --- the verdict ------------------------------------------------------
        let open = BridgeCheck.Status(build: "b", open: true, recv: 10, posted: 9, fetched: 9, pmax: 1023)
        expect(BridgeCheck.verdict(nil, ageSeconds: nil) == .notLoaded,
               "verdict: no status file -> SAI never loaded us")
        expect(BridgeCheck.verdict(open, ageSeconds: 60) == .notLoaded,
               "verdict: stale file is not evidence of a live bridge")
        expect(BridgeCheck.verdict(open, ageSeconds: 1) == .working,
               "verdict: fresh, open, samples in, packets read -> working")

        var st = open; st.open = false
        expect(BridgeCheck.verdict(st, ageSeconds: 1) == .noContext,
               "verdict: loaded but SAI never opened a context")
        st = open; st.recv = 0
        expect(BridgeCheck.verdict(st, ageSeconds: 1) == .noSamples,
               "verdict: nothing arriving from the mac side")
        st = open; st.fetched = 0
        expect(BridgeCheck.verdict(st, ageSeconds: 1) == .ignoring,
               "verdict: samples arrive, SAI reads nothing")

        // Every verdict must say something usable — an empty string here would
        // be a blank row in the setup window, which is worse than no row.
        for v in [BridgeCheck.Verdict.notLoaded, .noContext, .noSamples, .ignoring, .working] {
            expect(!BridgeCheck.explain(v, open).isEmpty, "explain: \(v) has a sentence")
        }

        print(failures == 0 ? "BridgeCheck: all passed" : "BridgeCheck: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

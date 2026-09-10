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

        // --- the probe: the far side, tested with SAI closed ------------------
        // Both fixtures below are REAL wtprobe.exe output, captured from the
        // same prefix: once healthy, and once broken exactly as #29 was. They
        // are pasted rather than composed so that a change to the probe's
        // wording is caught here instead of in the field.

        // A prefix in the #29 state. Note dll=loaded: something called
        // wintab32 DID load, which is precisely why every check the app used
        // to make came back green while SAI drew with the plain mouse.
        let probe29 = """
        probe=1
        dll=loaded
        ours=no
        build=-
        entrypoints=ok
        info=0
        defcontext=none
        ctx=failed
        secs=0
        """
        let p29 = BridgeCheck.parseProbe(probe29)
        expect(p29?.dllLoaded == true, "probe: #29 output — a wintab32 did load")
        expect(p29?.ours == false,     "probe: ...but not ours")
        expect(BridgeCheck.probeVerdict(p29) == .wineOwnDLL,
               "probe: #29 output reads as Wine's own DLL")
        expect(BridgeCheck.explainProbe(.wineOwnDLL, p29).contains("Repair"),
               "probe: and tells the reader what to press")

        // The healthy prefix with nobody touching the tablet. This must NOT
        // read as a fault: the bridge is proven up to the last inch, and the
        // only thing missing is a finger on the pen. Calling this broken would
        // send someone repairing a prefix that is fine.
        let probeIdle = """
        probe=1
        dll=loaded
        ours=yes
        build=Sep 10 2026 19:34:12
        entrypoints=ok
        info=200
        defcontext=ok
        ctx=open
        msgbase=32752
        msgs=0
        fetched=0
        down=0
        pmax_seen=0
        secs=4
        """
        let pIdle = BridgeCheck.parseProbe(probeIdle)
        expect(pIdle?.ours == true, "probe: healthy output — Wine loaded ours")
        expect(pIdle?.build == "Sep 10 2026 19:34:12",
               "probe: the build stamp keeps its spaces")
        expect(BridgeCheck.probeVerdict(pIdle) == .noPackets,
               "probe: loaded and open but untouched is 'no packets', not a fault")
        expect(BridgeCheck.explainProbe(.noPackets, pIdle).contains("Press the pen"),
               "probe: and asks for the one thing that was missing")

        // The same run with the pen actually pressed.
        let pLive = BridgeCheck.parseProbe(probeIdle
            .replacingOccurrences(of: "msgs=0", with: "msgs=412")
            .replacingOccurrences(of: "fetched=0", with: "fetched=409")
            .replacingOccurrences(of: "pmax_seen=0", with: "pmax_seen=3871"))
        expect(BridgeCheck.probeVerdict(pLive) == .working, "probe: packets arriving is working")
        expect(BridgeCheck.explainProbe(.working, pLive).contains("409"),
               "probe: and says how many actually arrived")

        // The trap that #29 IS: "a wintab32 loaded" must never outrank "whose".
        // A build that checked dllLoaded first, or that only looked at whether
        // packets arrived, would call this healthy — it is the exact shape of
        // the machine in the field report.
        var sneaky = BridgeCheck.Probe()
        sneaky.dllLoaded = true; sneaky.ours = false
        sneaky.entryPoints = true; sneaky.contextOpen = true
        sneaky.msgs = 99; sneaky.fetched = 99
        expect(BridgeCheck.probeVerdict(sneaky) == .wineOwnDLL,
               "probe: Wine's DLL stays the verdict even if packets flowed")

        // Wine failing to run the probe at all is a DIFFERENT answer from the
        // probe running and finding nothing, and they need opposite advice —
        // so output that isn't the probe's must not parse into an empty Probe.
        expect(BridgeCheck.parseProbe("wine: cannot find L\"wtprobe.exe\"") == nil,
               "probe: output that isn't the probe's is nil, not an empty result")
        expect(BridgeCheck.parseProbe("") == nil, "probe: no output at all is nil")
        expect(BridgeCheck.probeVerdict(nil) == .didNotRun,
               "probe: nil reads as 'did not run', not as a broken bridge")

        // --- taking whole lines off a stream ----------------------------------
        // THE TRAP, and it cost an evening: the probe is a WINDOWS program, so
        // its lines end CRLF, and Swift counts "\r\n" as ONE Character that is
        // not equal to "\n". A splitter written the obvious way finds no line
        // ending at all, the buffer grows for ever, and the received-side bar
        // sits at "starting…" while the probe streams perfectly into the pipe.
        var crlf = "probe=1\r\ndll=loaded\r\ntick=1 p=5"
        let got = BridgeCheck.takeLines(&crlf)
        expect(got == ["probe=1", "dll=loaded"], "lines: CRLF lines are split, and split clean")
        expect(crlf == "tick=1 p=5", "lines: the partial last line is kept for the next read")
        // ...and plain LF must keep working, because the tests and the unit
        // fixtures use it even where the real thing does not.
        var lf = "a\nb\n"
        expect(BridgeCheck.takeLines(&lf) == ["a", "b"], "lines: plain LF still splits")
        expect(lf.isEmpty, "lines: nothing left over when the last line was complete")
        // A read that lands between the CR and the LF must not invent a line.
        var split1 = "alpha\r"
        expect(BridgeCheck.takeLines(&split1) == ["alpha"], "lines: a chunk ending mid-CRLF yields its line")
        var split2 = "\nbeta\r\n"
        expect(BridgeCheck.takeLines(&split2) == ["beta"], "lines: and the orphaned LF adds nothing")

        var none = "no newline yet"
        expect(BridgeCheck.takeLines(&none).isEmpty, "lines: a fragment yields nothing")
        expect(none == "no newline yet", "lines: and is left in the buffer untouched")

        // --- the live ticks, streamed beside the pressure bar -----------------
        // Real line, as wtprobe.exe emits it ~10 times a second.
        let tick = BridgeCheck.parseTick("tick=1 p=1234 msgs=88 fetched=87 pmax=3381 down=80")
        expect(tick?.pressure == 1234, "tick: the live pressure drives the received bar")
        expect(tick?.fetched == 87 && tick?.msgs == 88, "tick: posted and read counted apart")
        expect(tick?.pmax == 3381, "tick: peak carried through")

        // The probe's header comes down the SAME pipe. Reading one of those as
        // an all-zero tick would park the received bar at zero mid-stroke —
        // i.e. show a working bridge as a dead one, the very fault being hunted.
        expect(BridgeCheck.parseTick("ours=yes") == nil, "tick: a header line is not a tick")
        expect(BridgeCheck.parseTick("dll=loaded") == nil, "tick: nor is dll=loaded")
        expect(BridgeCheck.parseTick("") == nil, "tick: nor is an empty line")
        // A partial line (the pipe split mid-write) must not read as a tick
        // either — it would report a pressure that was never sent.
        expect(BridgeCheck.parseTick("p=1234 msgs=88") == nil,
               "tick: a fragment without the tick marker is refused")

        // --- the verdict has to follow the ticks, not the header --------------
        // THE TRAP: the header is everything the probe says BEFORE its first
        // tick. It describes the wiring and cannot describe traffic, because
        // none has happened yet — so a verdict taken from it alone is fixed at
        // "no pen data reached it" and stays there while the received bar fills
        // up in front of you. That exact sentence sat under 1134 arrived
        // packets before this was fixed.
        let headerOnly = BridgeCheck.parseProbe(probeIdle)
        expect(BridgeCheck.probeVerdict(headerOnly) == .noPackets,
               "merge: before any tick, the honest answer is 'nothing yet'")
        let flowing = BridgeCheck.merging(headerOnly,
                        BridgeCheck.Tick(pressure: 1455, msgs: 1140, fetched: 1134, pmax: 4095, down: 900))
        expect(flowing?.fetched == 1134, "merge: the tick's counters land in the probe")
        expect(BridgeCheck.probeVerdict(flowing) == .working,
               "merge: and the verdict follows them to 'working'")
        expect(BridgeCheck.explainProbe(BridgeCheck.probeVerdict(flowing), flowing).contains("1134"),
               "merge: the sentence quotes what actually arrived")
        // Merging must not resurrect a probe that never ran, or a dead bridge
        // would start reporting traffic the moment a stray tick was parsed.
        expect(BridgeCheck.merging(nil, BridgeCheck.Tick(pressure: 1, msgs: 1, fetched: 1, pmax: 1, down: 1)) == nil,
               "merge: nothing to merge into stays nothing")

        for v in [BridgeCheck.ProbeVerdict.didNotRun, .noDLL, .wineOwnDLL, .unusable,
                  .noContext, .noPackets, .notReadable, .working] {
            expect(!BridgeCheck.explainProbe(v, pIdle).isEmpty, "probe: \(v) has a sentence")
        }

        print(failures == 0 ? "BridgeCheck: all passed" : "BridgeCheck: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

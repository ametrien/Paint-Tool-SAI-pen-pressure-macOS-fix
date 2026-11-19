// WineStartTests.swift — does Wine START, and what the user is told if not.
//
// The case behind this file: an Intel Wine on a Mac with an Apple chip and no
// Rosetta. The file is there, so the Wine row was green, but it cannot run,
// and every step after it failed without a word (WineStartCore.swift). That
// Mac cannot be had here, since this one has Rosetta, so the tests make a
// binary that fails to start in exactly the same way: a Mach-O for a
// processor no current Mac runs. posix_spawn refuses it with errno 86, "Bad
// CPU type in executable", the same answer an x86_64 Wine gets from an Apple
// chip without Rosetta.

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

func write(_ path: String, _ text: String, mode: Int16) {
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

/// Does this dialog script compile? Wrapped in `if false` so it is never shown.
func compiles(_ script: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "if false then", "-e", script, "-e", "end if"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

@main
struct WineStartTests {
    static func main() {
        print("WineStartCore tests:")
        let core = WineStartCore.self

        // ---- 1. the decision, from what starting `wine --version` produced ----
        expect(core.problem(spawnError: 86, exitStatus: nil, output: "", appleChip: true) == .needsRosetta,
               "decide: Bad CPU type on an Apple chip means Rosetta is missing (THE CASE)")
        expect(core.problem(spawnError: 86, exitStatus: nil, output: "", appleChip: false) == .cannotStart(code: 86),
               "decide: on an Intel Mac the same error is not about Rosetta")
        expect(core.problem(spawnError: 13, exitStatus: nil, output: "", appleChip: true) == .cannotStart(code: 13),
               "decide: any other refusal is reported with its code")
        expect(core.problem(spawnError: nil, exitStatus: 0, output: "wine-11.16 (Staging)\n", appleChip: true) == nil,
               "decide: a version on stdout and exit 0 is a Wine that starts")
        expect(core.problem(spawnError: nil, exitStatus: 1, output: "", appleChip: true) == .failed(status: 1),
               "decide: started and failed")
        expect(core.problem(spawnError: nil, exitStatus: 0, output: " \n", appleChip: true) == .failed(status: 0),
               "decide: started and said nothing is not a Wine that works")
        // THE TRAP on the other side: a slow first start under Rosetta must not
        // be called broken, or someone reinstalls a Wine that works.
        expect(core.problem(spawnError: nil, exitStatus: nil, output: "", appleChip: true) == nil,
               "decide: still running at the timeout is not a problem")

        // ---- 2. the real thing, against stand-ins that fail each way ----------
        let dir = NSTemporaryDirectory() + "winestart-\(getpid())"
        try? FileManager.default.removeItem(atPath: dir)
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // A 64-bit Mach-O header for PowerPC: magic, cputype 18, MH_EXECUTE.
        let badCPU = dir + "/wine-for-another-cpu"
        var header: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 0x12, 0, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0]
        header += [UInt8](repeating: 0, count: 16)
        FileManager.default.createFile(atPath: badCPU, contents: Data(header),
                                       attributes: [.posixPermissions: 0o755])
        let notRunnable = dir + "/wine-not-executable"
        write(notRunnable, "not a program\n", mode: 0o644)
        let starts = dir + "/wine-ok"
        write(starts, "#!/bin/sh\necho 'wine-11.16 (Staging)'\n", mode: 0o755)
        let failsAtOnce = dir + "/wine-fails"
        write(failsAtOnce, "#!/bin/sh\nexit 3\n", mode: 0o755)
        let silent = dir + "/wine-silent"
        write(silent, "#!/bin/sh\nexit 0\n", mode: 0o755)
        let slow = dir + "/wine-slow"
        write(slow, "#!/bin/sh\nexec sleep 30\n", mode: 0o755)

        var r = core.check(wine: badCPU, appleChip: true)
        expect(r == WineStartResult(version: nil, problem: .needsRosetta),
               "start: a binary this Mac's processor cannot run, on an Apple chip -> needs Rosetta (THE CASE)")
        r = core.check(wine: badCPU, appleChip: false)
        expect(r.problem == .cannotStart(code: 86), "start: the same binary on an Intel Mac -> cannot start, 86")
        expect(core.check(wine: notRunnable, appleChip: true).problem == .cannotStart(code: 2),
               "start: a file that is not executable -> cannot start")
        expect(core.check(wine: dir + "/missing", appleChip: true).problem == .cannotStart(code: 2),
               "start: no file at all -> cannot start")
        r = core.check(wine: starts, appleChip: true)
        expect(r == WineStartResult(version: "wine-11.16 (Staging)", problem: nil),
               "start: a Wine that answers gives its version and no problem")
        expect(core.check(wine: failsAtOnce, appleChip: true).problem == .failed(status: 3),
               "start: one that exits 3 -> failed, 3")
        expect(core.check(wine: silent, appleChip: true).problem == .failed(status: 0),
               "start: one that prints nothing -> failed")
        let t0 = Date()
        r = core.check(wine: slow, timeout: 1, appleChip: true)
        expect(r == WineStartResult(version: nil, problem: nil), "start: no answer in time -> unknown, not broken")
        expect(Date().timeIntervalSince(t0) < 5, "start: and the check gives up on time")
        Thread.sleep(forTimeInterval: 2.5)
        let left = Process()
        left.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        left.arguments = ["-f", slow]
        left.standardOutput = FileHandle.nullDevice
        try! left.run(); left.waitUntilExit()
        expect(left.terminationStatus != 0, "start: and leaves no process behind")

        // ---- 3. remembered, but never past a change to Wine -------------------
        let memo = WineStartMemo()
        memo.record(badCPU, WineStartResult(version: nil, problem: .needsRosetta))
        expect(memo.problem(for: badCPU) == .needsRosetta, "memo: the last answer is there for the window")
        expect(memo.problem(for: starts) == nil, "memo: and only for the Wine it was about")
        expect(memo.problem(for: nil) == nil, "memo: no Wine, no problem to show")
        let later = Date().addingTimeInterval(60)
        try! FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: badCPU)
        expect(memo.problem(for: badCPU) == nil, "memo: a Wine that changed since (reinstalled) is unknown again")

        // checkWineStarts: a working Wine is asked once, a broken one every time,
        // so installing Rosetta is noticed the next time anything asks.
        let countOK = dir + "/count-ok", countFail = dir + "/count-fail"
        write(dir + "/wine-counted-ok", "#!/bin/sh\necho x >> '\(countOK)'\necho 'wine-11.16 (Staging)'\n", mode: 0o755)
        write(dir + "/wine-counted-fail", "#!/bin/sh\necho x >> '\(countFail)'\nexit 1\n", mode: 0o755)
        func runs(_ f: String) -> Int {
            ((try? String(contentsOfFile: f, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        _ = checkWineStarts(dir + "/wine-counted-ok"); _ = checkWineStarts(dir + "/wine-counted-ok")
        expect(runs(countOK) == 1, "memo: a Wine that starts is not started again for every question")
        _ = checkWineStarts(dir + "/wine-counted-fail"); _ = checkWineStarts(dir + "/wine-counted-fail")
        expect(runs(countFail) == 2, "memo: a Wine that failed is asked again every time")
        _ = checkWineStarts(dir + "/wine-counted-ok", reuse: false)
        expect(runs(countOK) == 2, "memo: reuse: false always asks")

        // ---- 4. what the user sees -------------------------------------------
        let all: [WineStartProblem] = [.needsRosetta, .cannotStart(code: 13), .failed(status: 3)]
        for p in all {
            let line = core.rowLine(p)
            expect(line.count <= 60, "row: \(p) fits the row (\(line.count) characters)")
            expect([line, core.advice(p, button: true), core.advice(p, button: false)].allSatisfy { !$0.contains("—") },
                   "text: no em dash in what \(p) shows")
            // Through the same dialog every message uses, and it must compile:
            // a dialog that does not compile is never seen (OsaQuote.swift).
            expect(compiles(alertScript(core.advice(p, button: false))), "dialog: the advice for \(p) compiles")
        }
        expect(core.advice(.needsRosetta, button: true).contains("Rosetta"), "advice: names Rosetta")
        expect(core.advice(.needsRosetta, button: true).contains("Press Install Rosetta."),
               "advice: in the dialog with the button, points at that button")
        expect(core.advice(.needsRosetta, button: false).contains("Wine row"),
               "advice: in a plain OK dialog, points at the Wine row")
        expect(core.fixTitle(.needsRosetta) == "Install Rosetta…", "button: Install Rosetta…")
        expect(core.fixTitle(.failed(status: 1)) == "Reinstall Wine…", "button: otherwise Reinstall Wine…")

        // The Wine row itself.
        var row = core.wineRow(installed: false, problem: nil)
        expect(!row.ok && row.fixTitle == "Install Wine…", "row: no Wine, offer to install it")
        row = core.wineRow(installed: true, problem: nil)
        expect(row.ok && row.detail == core.installedLine, "row: a Wine that starts (or is not checked yet) is green")
        row = core.wineRow(installed: true, problem: .needsRosetta)
        expect(!row.ok && row.detail.contains("Rosetta") && row.fixTitle == "Install Rosetta…",
               "row: a Wine that needs Rosetta is NOT green, says so, and offers it (THE CASE)")

        // ---- 5. the green row says Rosetta was checked, on an Apple chip -------
        // The note is the visible proof the check ran and passed. THE TRAP: it
        // must never appear unless Wine was SEEN to run through Rosetta: not on
        // an Intel Mac, not for a Wine with Apple-chip code, not before the
        // check has answered, and never on a red row.
        row = core.wineRow(installed: true, problem: nil, viaRosetta: true)
        expect(row.ok && row.detail == core.installedLine + core.rosettaNote,
               "rosetta note: a Wine seen running through Rosetta says so on the green row")
        expect(row.detail.count <= 60, "rosetta note: and still fits the row (\(row.detail.count) characters)")
        expect(!row.detail.contains("—"), "rosetta note: no em dash")
        row = core.wineRow(installed: true, problem: nil)
        expect(!row.detail.contains("Rosetta"), "rosetta note: not before the check has answered")
        row = core.wineRow(installed: true, problem: .needsRosetta, viaRosetta: true)
        expect(!row.detail.contains(core.rosettaNote), "rosetta note: never on a red row")

        // Which binaries run through Rosetta, from their Mach-O header.
        func macho(_ name: String, _ bytes: [UInt8]) -> String {
            let p = dir + "/" + name
            FileManager.default.createFile(atPath: p, contents: Data(bytes + [UInt8](repeating: 0, count: 32)),
                                           attributes: [.posixPermissions: 0o755])
            return p
        }
        let thinX86 = macho("thin-x86_64", [0xcf, 0xfa, 0xed, 0xfe, 0x07, 0, 0, 0x01])
        let thinArm = macho("thin-arm64",  [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 0x01])
        // Universal: magic, 2 entries, then 20-byte entries (cputype first).
        let entry = { (cpu: UInt8) -> [UInt8] in [0x01, 0, 0, cpu] + [UInt8](repeating: 0, count: 16) }
        let fatBoth = macho("fat-both", [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2] + entry(0x07) + entry(0x0c))
        let fatX86  = macho("fat-x86",  [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1] + entry(0x07))
        expect(core.isIntelOnly(thinX86), "arch: an Intel-only program (Gcenx's Wine) runs through Rosetta")
        expect(core.isIntelOnly(fatX86), "arch: a universal file with only Intel code does too")
        expect(!core.isIntelOnly(thinArm), "arch: an Apple-chip program does not")
        expect(!core.isIntelOnly(fatBoth), "arch: a universal one with Apple-chip code runs natively, no note")
        expect(!core.isIntelOnly(starts), "arch: a script is not known to, no note")
        expect(!core.isIntelOnly(dir + "/missing"), "arch: no file, no note")
        expect(!core.isIntelOnly(badCPU), "arch: PowerPC is not Intel")
        // The real Gcenx Wine, when this Mac has it: x86_64 only.
        let gcenx = "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"
        if FileManager.default.fileExists(atPath: gcenx) {
            expect(core.isIntelOnly(gcenx), "arch: the installed Gcenx Wine is Intel-only")
        }
        // ---- 6. after Apple's Rosetta installer ------------------------------
        // Decided by starting Wine again, never by what the installer printed.
        // THE TRAP: saying "Wine starts now" when it has not answered, or
        // when there was no Wine to ask. The old code did exactly that.
        let ok = WineStartResult(version: "wine-11.16 (Staging)", problem: nil)
        expect(core.afterRosettaInstall(ok) == .works, "after Rosetta: Wine answers -> works")
        expect(core.afterRosettaInstall(WineStartResult(version: nil, problem: nil)) == .finished,
               "after Rosetta: no answer in time is not called working")
        expect(core.afterRosettaInstall(nil) == .finished, "after Rosetta: no Wine to ask is not called working")
        expect(core.afterRosettaInstall(WineStartResult(version: nil, problem: .needsRosetta)) == .stillMissing,
               "after Rosetta: still bad CPU type -> not installed yet (cancelled, no network)")
        expect(core.afterRosettaInstall(WineStartResult(version: nil, problem: .failed(status: 3)))
                   == .otherProblem(.failed(status: 3)),
               "after Rosetta: Wine fails another way -> that problem, with its own fix")
        expect(core.afterRosettaMessage(.works)?.contains("Wine starts now") == true, "after Rosetta: works says so")
        expect(core.afterRosettaMessage(.finished)?.contains("Wine starts now") == false,
               "after Rosetta: finished does NOT claim Wine starts")
        expect(core.afterRosettaMessage(.stillMissing)?.contains("isn't installed yet") == true,
               "after Rosetta: still missing says so and how to retry")
        expect(core.afterRosettaMessage(.otherProblem(.failed(status: 3))) == nil,
               "after Rosetta: another problem gets its fix dialog, not a plain message")
        for a: WineStartCore.AfterRosetta in [.works, .finished, .stillMissing] {
            let m = core.afterRosettaMessage(a)!
            expect(compiles(alertScript(m)), "after Rosetta: the \(a) message compiles, so it is seen")
            expect(!m.contains("—"), "after Rosetta: no em dash in the \(a) message")
        }
        // The installer itself: compiled here, never run (if false).
        expect(compiles(core.rosettaInstallScript), "Rosetta installer: its script compiles")
        expect(core.rosettaInstallScript.contains("softwareupdate --install-rosetta")
               && core.rosettaInstallScript.contains("with administrator privileges"),
               "Rosetta installer: Apple's softwareupdate, with macOS's own password window")

        // The dialog with the fixing button, for every problem.
        for p in all {
            let d = core.fixDialog(p)
            expect(compiles(d.script), "fix dialog: compiles for \(p), so it is seen")
            expect(d.script.contains(osaQuote(d.button)) && !d.button.contains("…"),
                   "fix dialog: its button is \(d.button), what the code waits for")
        }
        expect(core.fixDialog(.needsRosetta).button == "Install Rosetta", "fix dialog: Install Rosetta")

        // ---- 7. the problem report -------------------------------------------
        expect(core.rosettaReportLine(nil) == nil, "report: no Rosetta line on an Intel Mac")
        expect(core.rosettaReportLine(true) == "Rosetta: installed", "report: Rosetta installed")
        expect(core.rosettaReportLine(false)?.hasPrefix("Rosetta: NOT installed") == true,
               "report: Rosetta missing is said plainly (THE CASE)")
        expect(core.wineReportLine(ok, archs: "x86_64") == "Wine: wine-11.16 (Staging) [x86_64]",
               "report: a Wine that starts gives its version and processor")
        expect(core.wineReportLine(WineStartResult(version: nil, problem: .needsRosetta), archs: "x86_64")
                   .contains("DOES NOT START: Wine needs Rosetta"),
               "report: a Wine that needs Rosetta says so, not 'version unknown' (THE CASE)")
        expect(core.wineReportLine(WineStartResult(version: nil, problem: nil), archs: "")
                   == "Wine: version unknown (no answer in time)",
               "report: no answer in time is reported as that")
        // This Mac: the answer must agree with the system's own `arch` tool.
        let archTool = Process()
        archTool.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        archTool.arguments = ["-x86_64", "/usr/bin/true"]
        archTool.standardOutput = FileHandle.nullDevice; archTool.standardError = FileHandle.nullDevice
        try! archTool.run(); archTool.waitUntilExit()
        if core.isAppleChip() {
            expect(core.rosettaInstalled() == (archTool.terminationStatus == 0),
                   "report: on this Mac, Rosetta is reported the way `arch -x86_64` finds it")
        } else {
            expect(core.rosettaInstalled() == nil, "report: on this Intel Mac there is no Rosetta answer")
        }

        // ---- 8. Advanced › Wine for a Wine that does not start ----------------
        let adv = core.advancedLine(.needsRosetta)
        expect(adv.text.contains("Rosetta") && !adv.text.contains("No Wine installed"),
               "advanced: names Rosetta, never 'No Wine installed yet' (THE CASE)")
        expect(adv.button == "Install Rosetta…", "advanced: offers Install Rosetta…")
        expect(core.advancedLine(nil).button == nil, "advanced: no answer, no fix button to guess with")
        expect(!core.advancedLine(nil).text.contains("No Wine installed"), "advanced: and still not 'no Wine'")

        // check(): a Wine that answers but is a script is never "via Rosetta".
        expect(!core.check(wine: starts, appleChip: true).viaRosetta, "check: a script Wine gets no note")

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("All WineStartCore tests passed.")
    }
}

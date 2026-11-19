// WineStartCore.swift — does Wine actually START on this Mac, and if not, why.
//
// The Wine row used to turn green as soon as the file was in /Applications. On
// a Mac with an Apple chip and no Rosetta that file is there and cannot run:
// Gcenx's Wine is an Intel build (x86_64 only), and an Intel program on an
// Apple chip runs through Rosetta or not at all. Rosetta is not on a new Mac.
// macOS offers it when an Intel APP is opened from the Finder, but this app
// starts the wine binary directly, so macOS never offers anything and the
// start just fails with "Bad CPU type in executable" (errno 86).
//
// What that looked like to the user (reported on YouTube, 2026-11-17;
// reproduced 2026-11-19 with a binary that fails to start the same way):
// setup copied SAI and our DLL into the prefix, which are plain file copies,
// but could not write the registry setting, which takes Wine. Every row was
// green except "Pressure bridge: Wine loads its own wintab32, not ours. Press
// Repair." Repair could not work either, its "Couldn't repair the bridge" was
// never shown (OsaQuote.swift), and Advanced said "No Wine installed yet"
// beside a green Wine row.
//
// The decisions are pure and tested on their own; check() runs the real thing
// and is tested against stand-in binaries that fail in each of these ways
// (tests/WineStartTests.swift).

import Foundation

enum WineStartProblem: Equatable {
    /// An Intel Wine on an Apple chip without Rosetta.
    case needsRosetta
    /// macOS would not start it at all for another reason. The code is the
    /// errno (2: not there or not runnable, 13: no permission, 86: built for
    /// another processor).
    case cannotStart(code: Int32)
    /// It started, then failed or said nothing. The exit status.
    case failed(status: Int32)
}

struct WineStartResult: Equatable {
    /// What `wine --version` printed, e.g. "wine-11.16 (Staging)". nil when it
    /// could not be run, failed, or had not answered by the timeout.
    var version: String?
    /// nil when nothing is known to be wrong, which includes "had not answered
    /// by the timeout": slow is not broken.
    var problem: WineStartProblem?
    /// It answered, on an Apple chip, and it is an Intel-only binary: so it
    /// just ran through Rosetta, and Rosetta is proven to be there. The Wine
    /// row says so (wineRow). false whenever any of that is not known.
    var viaRosetta: Bool = false
}

enum WineStartCore {
    /// errno for "Bad CPU type in executable".
    static let badCPUType: Int32 = 86
    /// What the Wine row says while Wine is fine.
    static let installedLine = "Gcenx Wine Staging in /Applications"

    /// What went wrong, from what trying to run `wine --version` produced.
    /// - spawnError: errno when the process could not be started at all
    /// - exitStatus: nil when it was still running at the timeout
    /// - appleChip: whether this Mac has an Apple chip (isAppleChip)
    static func problem(spawnError: Int32?, exitStatus: Int32?, output: String,
                        appleChip: Bool) -> WineStartProblem? {
        if let e = spawnError {
            // On an Intel Mac an Intel Wine never fails this way, so there the
            // same errno means a Wine built for something else, not Rosetta.
            return e == badCPUType && appleChip ? .needsRosetta : .cannotStart(code: e)
        }
        // Still going at the timeout. Under Rosetta the very first start
        // translates the whole binary first, and a wrong "Wine is broken"
        // would send someone to reinstall a Wine that works.
        guard let status = exitStatus else { return nil }
        if status != 0 || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failed(status: status)
        }
        return nil
    }

    /// The errno in an error from Process.run(). Foundation reports a file it
    /// cannot run, missing or not executable, as its own "no such file" (Cocoa
    /// code 4) before trying, and anything posix_spawn refused as POSIX.
    static func errno(of error: Error) -> Int32 {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain {
            return Int32(u.code)
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileNoSuchFileError { return 2 }   // ENOENT
        return -1
    }

    /// One line for the Wine row. Under about sixty characters: the row
    /// truncates, and a warning cut off mid-sentence is worse than a short one.
    static func rowLine(_ p: WineStartProblem) -> String {
        switch p {
        case .needsRosetta:          return "Wine needs Rosetta, which isn't on this Mac yet."
        case .cannotStart(let code): return "Wine is here, but macOS won't start it (error \(code))."
        case .failed(let status):    return "Wine is here, but it stops at once (exit \(status))."
        }
    }

    /// The Wine row's button while Wine cannot start.
    static func fixTitle(_ p: WineStartProblem) -> String {
        p == .needsRosetta ? "Install Rosetta…" : "Reinstall Wine…"
    }

    /// The dialog. button: the dialog itself has the button that fixes it;
    /// otherwise it is a plain OK and the fix is on the Wine row.
    static func advice(_ p: WineStartProblem, button: Bool) -> String {
        let reinstall = button ? "Press Reinstall Wine. The old copy goes to the Trash."
                               : "Press Reinstall Wine… on the Wine row of the Setup tab."
        switch p {
        case .needsRosetta:
            return "Wine can't start on this Mac.\n\n"
                + "Wine is an app for Intel Macs. A Mac with an Apple chip runs it through Rosetta, "
                + "a free add-on from Apple, and Rosetta isn't installed on this Mac yet.\n\n"
                + (button ? "Press Install Rosetta. Your Mac asks for your password, and it takes a minute or two."
                          : "Press Install Rosetta… on the Wine row of the Setup tab. It takes a minute or two.")
        case .cannotStart(let code):
            return "Wine is installed, but macOS won't start it (error \(code): \(String(cString: strerror(code)))).\n\n"
                + reinstall
        case .failed(let status):
            return "Wine is installed, but it stops as soon as it starts (exit status \(status)).\n\n"
                + reinstall
        }
    }

    /// The dialog that says why Wine does not start and offers the fix, and
    /// the name of the button that fixes it (what osa returns when pressed).
    static func fixDialog(_ p: WineStartProblem) -> (script: String, button: String) {
        let button = fixTitle(p).replacingOccurrences(of: "…", with: "")
        let script = "button returned of (display dialog \(osaQuote(advice(p, button: true))) "
            + "buttons {\"Not now\", \(osaQuote(button))} default button \(osaQuote(button)) with icon caution)"
        return (script, button)
    }

    /// Apple's own Rosetta installer, run as administrator: macOS asks for the
    /// password in its usual window. --agree-to-license stands for the licence
    /// of Apple's that comes with it, which is what the user agrees to by
    /// pressing Install Rosetta.
    static let rosettaInstallScript =
        "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"

    enum AfterRosetta: Equatable {
        /// Wine answered: Rosetta is there and works.
        case works
        /// Nothing is wrong that anyone can see, but Wine has not answered
        /// either (slow first start, or no Wine to ask).
        case finished
        /// Wine still cannot start for want of Rosetta: cancelled, no network.
        case stillMissing
        /// Rosetta is there now, and Wine fails for another reason.
        case otherProblem(WineStartProblem)
    }

    /// What starting Wine again after the installer says. Decided by Wine,
    /// not by what the installer printed. nil: there was no Wine to start.
    static func afterRosettaInstall(_ r: WineStartResult?) -> AfterRosetta {
        guard let r = r else { return .finished }
        switch r.problem {
        case nil:           return r.version == nil ? .finished : .works
        case .needsRosetta: return .stillMissing
        case let p?:        return .otherProblem(p)
        }
    }

    /// The message for each outcome. otherProblem has none: its dialog is
    /// fixDialog, with the button that fixes it.
    static func afterRosettaMessage(_ a: AfterRosetta) -> String? {
        switch a {
        case .works:
            return "Rosetta is installed, and Wine starts now.\n\nPress Launch. SAI and the pressure bridge are set up on the way."
        case .finished:
            return "Rosetta's installer has finished.\n\nPress Launch. If Wine still can't start, the Wine row on the Setup tab says why."
        case .stillMissing:
            return "Rosetta isn't installed yet.\n\nPress Install Rosetta… on the Wine row to try again."
        case .otherProblem:
            return nil
        }
    }

    /// The problem report's Rosetta line. nil on an Intel Mac, where it does
    /// not apply. installed: rosettaInstalled().
    static func rosettaReportLine(_ installed: Bool?) -> String? {
        installed.map { "Rosetta: " + ($0 ? "installed" : "NOT installed (Intel apps, Wine among them, cannot run)") }
    }

    /// The problem report's Wine line: whether it STARTS, and if not why.
    /// "version unknown" was all a report said about an Intel Wine on an
    /// Apple chip without Rosetta. archs: what `lipo -archs` printed.
    static func wineReportLine(_ r: WineStartResult, archs: String) -> String {
        let what = r.version
            ?? r.problem.map { "DOES NOT START: \(rowLine($0))" }
            ?? "version unknown (no answer in time)"
        return "Wine: \(what)\(archs.isEmpty ? "" : " [\(archs)]")"
    }

    /// Advanced › Wine for a Wine that is there and does not answer. Not "No
    /// Wine installed yet", which is what it said beside a green Wine row on
    /// the Setup tab. button: the fix, when the reason is known.
    static func advancedLine(_ p: WineStartProblem?) -> (text: String, button: String?) {
        ((p.map(rowLine) ?? "Wine is here, but it doesn't answer.") + " The Wine row on the Setup tab can fix it.",
         p.map(fixTitle))
    }

    /// Added to the green Wine row once Wine has been seen to run through
    /// Rosetta, so the row shows the Rosetta check passed, not only that the
    /// file is there.
    static let rosettaNote = " · runs through Rosetta"

    /// The Wine row. installed: the file is there. problem: what the last start
    /// check found. viaRosetta: the last check saw it run through Rosetta
    /// (WineStartResult.viaRosetta). A Wine that has not been checked yet stays
    /// green without the note: the check runs a moment after the window opens,
    /// and accusing a Wine that works is worse than a second's delay.
    static func wineRow(installed: Bool, problem: WineStartProblem?, viaRosetta: Bool = false)
        -> (ok: Bool, detail: String, fixTitle: String) {
        guard installed else { return (false, installedLine, "Install Wine…") }
        if let p = problem { return (false, rowLine(p), fixTitle(p)) }
        return (true, installedLine + (viaRosetta ? rosettaNote : ""), "Install Wine…")
    }

    /// Is this file a Mach-O program for Intel only, with no Apple-chip code
    /// in it? Such a program runs on an Apple chip only through Rosetta.
    /// Reads the header: a thin binary names one processor, a universal ("fat")
    /// one lists every processor it has code for. Anything else (a script, a
    /// file that is not there) is false: nothing is known about it.
    static func isIntelOnly(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let head = [UInt8](fh.readData(ofLength: 4096))
        guard head.count >= 8 else { return false }
        func le32(_ o: Int) -> UInt32 {
            UInt32(head[o]) | UInt32(head[o+1]) << 8 | UInt32(head[o+2]) << 16 | UInt32(head[o+3]) << 24
        }
        func be32(_ o: Int) -> UInt32 {
            UInt32(head[o]) << 24 | UInt32(head[o+1]) << 16 | UInt32(head[o+2]) << 8 | UInt32(head[o+3])
        }
        let x86_64: UInt32 = 0x0100_0007, arm64: UInt32 = 0x0100_000c
        var cpus: [UInt32] = []
        switch be32(0) {
        case 0xcffa_edfe:                       // thin 64-bit, little-endian on disk
            cpus = [le32(4)]
        case 0xcafe_babe, 0xcafe_babf:          // universal; entries are 20 or 32 bytes
            let size = be32(0) == 0xcafe_babe ? 20 : 32
            let n = Int(min(be32(4), 32))
            for i in 0..<n {
                let o = 8 + i * size
                guard o + 4 <= head.count else { break }
                cpus.append(be32(o))
            }
        default:
            return false
        }
        return cpus.contains(x86_64) && !cpus.contains(arm64)
    }

    /// An Apple chip? Asks the hardware, so the answer is the same when this
    /// app itself runs under Rosetta.
    static func isAppleChip() -> Bool {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }

    /// Is Rosetta installed? nil on an Intel Mac, where it does not apply.
    /// Runs a system tool as Intel, which only works through Rosetta. For the
    /// problem report: the app itself decides from what Wine does.
    static func rosettaInstalled() -> Bool? {
        guard isAppleChip() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Run `wine --version` and say what happened. Blocks for as long as Wine
    /// takes, up to the timeout, so never call it on the main thread.
    static func check(wine: String, timeout: TimeInterval = 30,
                      appleChip: Bool = isAppleChip()) -> WineStartResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: wine)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return WineStartResult(version: nil,
                                   problem: problem(spawnError: errno(of: error), exitStatus: nil,
                                                    output: "", appleChip: appleChip))
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            // Not answering is not proof of anything, and the check must not
            // leave a process behind either.
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
            return WineStartResult(version: nil, problem: nil)
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let found = problem(spawnError: nil, exitStatus: p.terminationStatus, output: text,
                            appleChip: appleChip)
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let answered = found == nil && !version.isEmpty
        return WineStartResult(version: answered ? version : nil, problem: found,
                               viaRosetta: answered && appleChip && isIntelOnly(wine))
    }
}

/// The last start check, so the setup window can show it every second without
/// starting Wine every second. Tied to the binary's path and modification
/// date: a Wine that was reinstalled or updated since is checked afresh.
/// Written from background threads and read by the window, hence the lock.
final class WineStartMemo {
    private let lock = NSLock()
    private var path: String?
    private var stamp: Date?
    private var last: WineStartResult?

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func record(_ wine: String, _ r: WineStartResult) {
        let m = modified(wine)
        lock.lock(); defer { lock.unlock() }
        path = wine; stamp = m; last = r
    }

    /// nil when this Wine was never checked, or has changed since.
    func result(for wine: String) -> WineStartResult? {
        let m = modified(wine)
        lock.lock(); defer { lock.unlock() }
        guard wine == path, m == stamp else { return nil }
        return last
    }

    func problem(for wine: String?) -> WineStartProblem? {
        wine.flatMap { result(for: $0)?.problem }
    }
}

let g_wineStart = WineStartMemo()

/// WineStartCore.check, remembered. "Starts fine" is reused for the same
/// binary, so a launch does not pay for a check the window already made; a
/// problem is always checked again, so installing Rosetta is noticed the next
/// time anything asks. An answer of "did not answer in time" changes nothing.
func checkWineStarts(_ wine: String, reuse: Bool = true) -> WineStartResult {
    if reuse, let r = g_wineStart.result(for: wine), r.problem == nil, r.version != nil { return r }
    let r = WineStartCore.check(wine: wine)
    if r.problem != nil || r.version != nil { g_wineStart.record(wine, r) }
    return r
}

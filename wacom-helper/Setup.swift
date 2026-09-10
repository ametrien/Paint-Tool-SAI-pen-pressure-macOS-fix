// Setup.swift — installing, repairing, updating and removing the Wine prefix
// that SAI runs in.
//
// Moved out of main.swift unchanged. This is where the app does its heaviest and
// least reversible work: it deletes the prefix, copies SAI into it, and can take
// the whole installation away again. The licence rescue that wraps the deletion
// lives in Licence.swift, and the two are meant to be read together.
//
// updateSAIFromFolder is covered by tests/run-tests.sh against a throwaway
// prefix. performSetup itself is not: it needs a real wineboot, so it is on the
// manual checklist in TESTING.md.

import AppKit
import Foundation

/// Which of the two locations actually hold a certificate right now. Shown in
/// the UI because "it says installed but SAI won't save" is impossible to debug
/// blind — seeing the real paths makes a half-install obvious at a glance.
enum SetupMode {
    case ensure     // install only if nothing usable is there (or the source changed)
    case repair     // re-copy SAI + the bridge over the existing prefix; keep licence
    case rebuild    // delete the whole prefix and build it from scratch; restore licence
}
/// Install the pressure bridge (our DLL + the registry overrides) into the prefix.
/// Split out so repair can redo it without touching SAI itself.
/// Stop everything Wine is running for OUR prefix, and wait until it is really
/// gone. Call before anything that deletes or rebuilds the prefix (issue #28).
///
/// `wineserver` is a per-prefix daemon that outlives both SAI and this app.
/// Deleting a prefix while its server is still alive leaves the daemon running
/// against files that no longer exist, and a later `wine` can attach to that
/// stale server instead of starting cleanly — a documented time-sink here: it
/// silently invalidated an entire Wine-version test in one session.
///
/// `-k` terminates the server, `-w` blocks until it has actually exited. Using
/// wineserver's own wait beats sleeping and hoping, because no fixed delay is
/// both short enough to feel instant and long enough to always be right.
///
/// The wait is still bounded: a wedged daemon must not freeze the uninstall
/// dialog. Returning false and carrying on is the better failure — the caller
/// is about to delete the prefix anyway, and a beachball with no explanation is
/// worse than a rare unclean stop.
@discardableResult
func stopWineForPrefix(_ wine: String, timeout: Double = 10) -> Bool {
    let ws = ((wine as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("wineserver")
    guard FileManager.default.isExecutableFile(atPath: ws) else { return false }
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    _ = runProc(ws, ["-k"], env: env)                    // terminate it
    let p = runProc(ws, ["-w"], env: env, wait: false)   // …and wait for it to be gone
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate(); return false }
    return true
}
func installBridge(_ wine: String) {
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    if let res = Bundle.main.resourcePath {
        let sys = "\(appPrefix)/drive_c/windows/system32"
        try? FileManager.default.createDirectory(atPath: sys, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: "\(sys)/wintab32.dll")
        try? FileManager.default.copyItem(atPath: "\(res)/wintab32.dll", toPath: "\(sys)/wintab32.dll")
    }
    runProc(wine, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "wintab32",
                   "/t", "REG_SZ", "/d", "native,builtin", "/f"], env: env)
}
// ---- the half of the bridge that lives in the Wine registry ---------------
// Installing our wintab32.dll is only half the job: Wine prefers its OWN
// built-in one unless the prefix says otherwise, so without the DllOverrides
// key the file we so carefully keep up to date is never loaded at all. SAI then
// draws from the plain mouse — strokes appear, pressure is flat, and every
// check the app used to make still passed (#29).
//
// The key was written once, by installBridge(), and nothing looked at it again.
// A prefix that never got it — built by a version older than the marker, or
// left behind by a reset that failed to finish — could not be healed by any
// number of relaunches, because performSetup(.ensure) returns early whenever
// sai2.exe is present. So it is checked on every launch now, and repaired in
// place. Checking is free (user.reg is a text file); repairing costs one wine
// call, and only when something is actually wrong.

/// Where Wine keeps HKEY_CURRENT_USER for this prefix.
func userRegPath() -> String { "\(appPrefix)/user.reg" }

/// Read user.reg as text. Wine writes it UTF-8, but an old prefix can carry
/// bytes that aren't valid UTF-8; latin-1 never fails, and a mis-decoded stray
/// byte elsewhere in the file cannot change the answer we're looking for.
func readUserReg() -> String? {
    if let s = try? String(contentsOfFile: userRegPath(), encoding: .utf8) { return s }
    return try? String(contentsOfFile: userRegPath(), encoding: .isoLatin1)
}

/// Set when we repair the override and verify it through wine. Consulted until
/// user.reg catches up, which can take the whole of an SAI session.
var g_overrideRepairedAt: Date?

/// Is this prefix set to load OUR wintab32 rather than Wine's built-in one?
func bridgeOverrideInstalled() -> Bool {
    if let text = readUserReg(),
       BridgeCheck.overrideIsNative(BridgeCheck.overrideValue(inUserReg: text)) { return true }
    // The file lags a repair: wineserver rewrites user.reg only when it exits,
    // so between repairing and that moment the file still names the value we
    // replaced — and while SAI is up, wineserver never exits, so it names it
    // for the entire session. Reading it alone made the app go on accusing a
    // prefix it had just fixed, in the setup row, in Copy diagnostics and in
    // the Repair button's own answer. A repair we verified through wine
    // therefore stands in for the file until the file agrees.
    if let t = g_overrideRepairedAt, Date().timeIntervalSince(t) < 3600 { return true }
    return false
}

/// Put the override back if it is missing or points at the built-in DLL.
///
/// Written through `wine reg add`, never by editing user.reg ourselves: the
/// wineserver holds the registry in memory and rewrites the file when it exits,
/// so a hand-edit made while anything is running is silently reverted. Must
/// therefore happen BEFORE SAI starts — which is where it is called from.
///
/// Returns true when it actually repaired something (so callers can say so).
@discardableResult
func ensureBridgeOverride(_ wine: String?) -> Bool {
    if bridgeOverrideInstalled() { return false }
    guard let w = wine else {
        wlog("bridge: DLL override missing and no Wine to repair it with")
        return false
    }
    wlog("bridge: DllOverrides wintab32 missing or not native — repairing")
    runProc(w, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "wintab32",
                "/t", "REG_SZ", "/d", "native,builtin", "/f"],
            env: ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"])
    // Verified through wine, NOT by re-reading user.reg — see bridgeOverrideViaWine.
    let ok = BridgeCheck.overrideIsNative(bridgeOverrideViaWine(w))
    if ok { g_overrideRepairedAt = Date() }
    wlog("bridge: override after repair = \(ok ? "native,builtin" : "STILL MISSING")")
    return ok
}

/// The override as WINESERVER holds it, rather than as user.reg spells it.
///
/// `wine reg add` writes into the registry wineserver keeps in MEMORY; the file
/// on disk only catches up when wineserver exits — measured at ~5s after the
/// last client quits on this machine, and not at all while SAI is up. So a
/// repair that verified itself by re-reading user.reg read back the very value
/// it had just replaced, and called a successful repair a failure: the Repair
/// button answered "Couldn't repair the bridge" and the log said
/// "override after repair = STILL MISSING", both while the key was, seconds
/// later, correct on disk. `reg query` asks the same in-memory registry the
/// write went to, so it answers about what SAI would actually load next.
///
/// Costs a wine spawn, so it is only used to check a write we just made;
/// bridgeOverrideInstalled() keeps reading the file, which is accurate whenever
/// nothing is mid-flight and free enough to call from a UI refresh.
func bridgeOverrideViaWine(_ wine: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: wine)
    p.arguments = ["reg", "query", "HKCU\\Software\\Wine\\DllOverrides", "/v", "wintab32"]
    var e = ProcessInfo.processInfo.environment
    e["WINEPREFIX"] = appPrefix; e["WINEDEBUG"] = "-all"
    p.environment = e
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    // Drain before waiting: reg's output is small, but waiting first on a full
    // pipe is the classic way to deadlock a Process.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
    return BridgeCheck.overrideValue(inRegQuery: text)
}

/// Where our DLL has to end up for Wine to find it.
func bridgeDLLPath() -> String { "\(appPrefix)/drive_c/windows/system32/wintab32.dll" }

/// Is the DLL in the prefix byte-identical to the one shipped in this app?
/// True in dev mode (running outside a bundle), where there is nothing to
/// compare against and a red row would be noise.
func bridgeDLLMatchesApp() -> Bool {
    guard let res = Bundle.main.resourcePath,
          let shipped = FileManager.default.contents(atPath: "\(res)/wintab32.dll") else { return true }
    return FileManager.default.contents(atPath: bridgeDLLPath()) == shipped
}

/// What the DLL reports from inside SAI, and how many seconds ago it said so.
/// (nil, nil) means the file has never appeared — SAI has not loaded us.
func bridgeStatus() -> (BridgeCheck.Status?, Double?) {
    let path = "\(appPrefix)/drive_c/wt_status.txt"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let st = BridgeCheck.parseStatus(text) else { return (nil, nil) }
    let mod = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
    return (st, mod.map { Date().timeIntervalSince($0) })
}

/// Everything the app can check about the bridge without SAI running.
func bridgeInstalledOK() -> Bool { bridgeDLLMatchesApp() && bridgeOverrideInstalled() }

/// Is SAI — the one running inside OUR Wine prefix — on screen right now?
///
/// Not saiWindowIsOpen(): that matches any window whose owner name contains
/// "sai", and this app is called "SAI Pen Pressure". It excludes its own pid,
/// which is enough for its own callers, but not for this one — a second copy of
/// the app, or a helper binary asking the same question, sees our setup window
/// and answers yes. Here the answer decides whether to accuse the bridge of
/// never loading, so a false yes is a fabricated fault. Caught by the bridge
/// tests, which run a second binary while the app is open.
func saiRunningInWine() -> Bool {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                           kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        if owner.contains("pen pressure") { continue }          // that's us, whoever is asking
        if owner.contains("sai2") || owner.contains("wine") { return true }
    }
    return false
}

/// One line for the setup window.
///
/// Order is the whole design here. What the DLL reports from INSIDE SAI outranks
/// anything we can check from out here: if SAI is drawing points from the pen
/// right now, a row announcing that something is broken is simply wrong (a
/// mismatched DLL file, for instance, only matters from the next launch). Our
/// own checks take over the moment that live answer is missing — and when SAI is
/// on screen with nothing to say for itself, THAT is the report from #29, and it
/// gets said in as many words.
///
/// Every line here is kept under about sixty characters: the row truncates, and
/// a warning cut off mid-sentence ("— Repair replac") is worse than a short one.
func bridgeDetailLine() -> String {
    let (st, age) = bridgeStatus()
    let live: BridgeCheck.Verdict? = (age.map { $0 <= 5 } ?? false)
        ? BridgeCheck.verdict(st, ageSeconds: age) : nil

    if let v = live, v != .notLoaded {
        return BridgeCheck.explain(v, st) + (bridgeInstalledOK() ? "" : " (Repair pending.)")
    }
    // Nothing is set up yet. The bridge is installed together with SAI on the
    // first Launch, and anything sterner reads as a fault on a machine that has
    // simply never been set up — which is exactly how it read the first time
    // this row was seen on a fresh install.
    if !saiInstalledInPrefix() { return "Installed with SAI when you press Launch." }
    if !FileManager.default.fileExists(atPath: bridgeDLLPath()) {
        return "Our wintab32.dll isn't in the prefix — press Repair."
    }
    if !bridgeDLLMatchesApp() {
        return "A different wintab32.dll than this app's — press Repair."
    }
    if !bridgeOverrideInstalled() {
        return "Wine loads its OWN wintab32 — no pressure. Press Repair."
    }
    // Our files are right, SAI is up, and the far side is silent: it never
    // loaded us. This is the sentence that would have ended #29 on day one.
    if saiRunningInWine() { return BridgeCheck.explain(.notLoaded, st) }
    return "Ready. While SAI is running, this row shows what it gets."
}

/// Keep the DLL inside the prefix identical to the one shipped in this app.
///
/// The helper and the DLL are a matched pair: they share `maxPressure` /
/// `WTC_MAX_PRESS` over a wire format with no version field. A new helper
/// scaling to 8191 against an old DLL that clamps at 1023 would pin every
/// stroke at full pressure — worse than the quantisation it fixes (issue #21).
///
/// Users update the app without re-running setup all the time, which would
/// leave a stale DLL in the prefix forever. So check on every launch and heal
/// it: a byte compare of a 138 KB file is far cheaper than that failure mode.
@discardableResult
func ensureBridgeUpToDate(_ wine: String?) -> Bool {
    guard let res = Bundle.main.resourcePath else { return false }
    let shipped = "\(res)/wintab32.dll"
    let sys = "\(appPrefix)/drive_c/windows/system32"
    let installed = "\(sys)/wintab32.dll"
    guard let want = FileManager.default.contents(atPath: shipped) else { return false }
    if FileManager.default.contents(atPath: installed) == want { return false }   // already current
    wlog("bridge: installed wintab32.dll differs from the shipped one — updating")
    try? FileManager.default.createDirectory(atPath: sys, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: installed)
    guard (try? FileManager.default.copyItem(atPath: shipped, toPath: installed)) != nil else { return false }
    if let w = wine {                        // re-assert the override, harmless if already set
        runProc(w, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "wintab32",
                    "/t", "REG_SZ", "/d", "native,builtin", "/f"],
                env: ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"])
    }
    return true
}
@discardableResult
func performSetup(_ saiSrc: String, _ wine: String, mode: SetupMode = .ensure, quiet: Bool = false,
                  progress: SetupProgress? = nil) -> Bool {
    if mode == .ensure, saiInstalledInPrefix(), !prefixIsStale() { return true }

    // Fail fast (before the ~1-minute wineboot) with a SPECIFIC message if the
    // chosen SAI folder is gone or doesn't actually contain sai2.exe — e.g. the
    // user moved/deleted it after picking it, or picked the wrong level.
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: saiSrc, isDirectory: &isDir), isDir.boolValue else {
        alertUser("The SAI folder you chose can't be found anymore:\n\n\(saiSrc)\n\nIt may have been moved, renamed, or deleted. Reopen the app and choose your SAI Ver.2 folder again.")
        try? FileManager.default.removeItem(atPath: appSupport() + "/config.txt")   // clear the stale path so the app re-asks
        return false
    }
    guard FileManager.default.fileExists(atPath: "\(saiSrc)/sai2.exe") else {
        alertUser("That folder doesn't contain sai2.exe:\n\n\(saiSrc)\n\nPick the folder that DIRECTLY contains sai2.exe (usually named like \"SAI Ver.2 64bit ...\").")
        try? FileManager.default.removeItem(atPath: appSupport() + "/config.txt")
        return false
    }

    // Take any certificate in the SOURCE folder under management before we touch
    // anything. Adopting only when the user PICKS a folder (adoptSAIFolder) was
    // not enough: anyone who chose their folder in an earlier version never
    // picks again, so the stash stayed empty and a rebuild still lost the
    // licence — the fix shipped without reaching the people who needed it.
    // Doing it here covers first setup, repair and rebuild alike, and it must
    // happen BEFORE the prefix is deleted. Reading from saiSrc, which we never
    // modify, so a rebuild cannot destroy what we are about to copy.
    adoptLicenseFromSourceFolder(saiSrc)

    if !quiet {
        let what = mode == .rebuild ? "Rebuilding the Wine prefix from scratch"
                 : (saiInstalledInPrefix() ? "Reinstalling SAI into the Wine prefix"
                                           : "Setting up SAI for the first time")
        alertUser("\(what) — this takes about a minute after you click OK. Please wait for SAI to appear.")
    }

    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    // Everything below rewrites the prefix, so nothing may still be using it —
    // including a wineserver left over from a previous session (#28).
    progress?(0.00, 0.06, "Stopping Wine…", 1)
    stopWineForPrefix(wine)
    if mode == .rebuild {
        // The whole point of a rebuild: nothing from the old prefix survives.
        // The licence is restored afterwards from our own stash, not from here —
        // so anything the prefix holds and the stash does not must be rescued
        // NOW. The later "keep any certificate already in there" step cannot
        // help: it guards prefixSAIDir, and the line below deletes the whole
        // prefix above it.
        adoptLicenseFromSourceFolder(prefixSAIDir)
        progress?(0.06, 0.12, "Removing the old Wine prefix…", 3)
        try? FileManager.default.removeItem(atPath: appPrefix)
    }
    // By far the longest step, and the one that made the window look frozen.
    progress?(0.12, 0.70, "Preparing the Wine environment… (about a minute)", 60)
    runProc(wine, ["wineboot", "-u"], env: env)

    // Re-copy SAI. For repair/rebuild the destination is cleared first, so files
    // deleted from the source don't linger and a broken install can't survive.
    if mode != .ensure, FileManager.default.fileExists(atPath: prefixSAIDir) {
        progress?(0.70, 0.74, "Clearing the old SAI copy…", 2)
        // keep any certificate that's already in there
        for f in slcFiles(in: prefixSAIDir) { installLicenseFile("\(prefixSAIDir)/\(f)") }
        try? FileManager.default.removeItem(atPath: prefixSAIDir)
    }
    try? FileManager.default.createDirectory(atPath: prefixSAIDir, withIntermediateDirectories: true)
    progress?(0.74, 0.94, "Copying SAI into the Wine prefix…", 12)
    runProc("/bin/cp", ["-R", "\(saiSrc)/.", prefixSAIDir])
    guard saiInstalledInPrefix() else {
        alertUser("Something went wrong copying SAI into the Wine prefix. Check that you have free disk space and that the SAI folder is readable, then reopen the app and try again."); return false
    }

    progress?(0.94, 1.00, "Installing the pressure bridge…", 2)
    installBridge(wine)
    restoreStashedLicenses()
    setInstalledSrcPath(saiSrc)          // the prefix now matches this source
    return saiInstalledInPrefix()
}
/// What in the prefix's SAI folder belongs to the USER rather than to the
/// program. A SAI update replaces the program; touching these would throw away
/// exactly the things nobody wants to set up twice.
///
///   sai2.ini    window layout, tool options, preferences
///   settings/   brushes, palettes, presets
///   history.txt recent files
///
/// Licences (*.slc) are handled separately by the existing stash, because they
/// can also live outside this folder.
let saiUserFiles = ["sai2.ini", "settings", "history.txt"]
/// Swap in a newer SAI without redoing the whole install.
///
/// SAI Ver.2 is a rolling preview and gets updated often, so "replace the
/// program, keep everything of mine" is the common case. A full Reinstall would
/// do it, but it also reboots the Wine prefix and clears the SAI folder, which
/// costs a minute and loses brushes and preferences for no reason. This copies
/// the new build over the old one and puts the user's files back.
///
/// Returns nil on success, or a message describing what stopped it.
func updateSAIFromFolder(_ newSrc: String) -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: "\(newSrc)/sai2.exe") else {
        return "That folder doesn't contain sai2.exe.\n\n\(newSrc)\n\nPick the folder that DIRECTLY contains sai2.exe."
    }
    guard fm.fileExists(atPath: prefixSAIDir) else {
        return "SAI isn't installed in the Wine prefix yet — use Reinstall / Repair first."
    }

    // Stash the user's files somewhere the copy cannot reach.
    let stash = NSTemporaryDirectory() + "sai-update-stash-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: stash, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: stash) }

    var saved: [String] = []
    for name in saiUserFiles where fm.fileExists(atPath: "\(prefixSAIDir)/\(name)") {
        if (try? fm.copyItem(atPath: "\(prefixSAIDir)/\(name)", toPath: "\(stash)/\(name)")) != nil {
            saved.append(name)
        }
    }
    // Licences go through the existing stash, which also covers copies kept
    // outside this folder.
    for f in slcFiles(in: prefixSAIDir) { _ = installLicenseFile("\(prefixSAIDir)/\(f)") }

    // Clear and re-copy, so files removed in the new build do not linger. This
    // is why the user's files had to be stashed rather than merely copied over.
    try? fm.removeItem(atPath: prefixSAIDir)
    try? fm.createDirectory(atPath: prefixSAIDir, withIntermediateDirectories: true)
    runProc("/bin/cp", ["-R", "\(newSrc)/.", prefixSAIDir])
    guard saiInstalledInPrefix() else {
        return "Copying the new SAI into the Wine prefix failed. Check free disk space and that the folder is readable."
    }

    // Put the user's files back, overwriting anything the new build shipped
    // under the same name — their settings win over the defaults.
    for name in saved {
        try? fm.removeItem(atPath: "\(prefixSAIDir)/\(name)")
        try? fm.copyItem(atPath: "\(stash)/\(name)", toPath: "\(prefixSAIDir)/\(name)")
    }
    restoreStashedLicenses()
    setInstalledSrcPath(newSrc)
    return nil
}

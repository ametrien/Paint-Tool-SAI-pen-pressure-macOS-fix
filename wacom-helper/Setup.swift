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

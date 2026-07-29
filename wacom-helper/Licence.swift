// Licence.swift — the SAI certificate: finding it, installing it, and keeping a
// copy so a rebuilt Wine prefix can have it back.
//
// Moved out of main.swift unchanged. It is gathered in one file because it is
// the only thing this app touches that a user cannot recreate: every call here
// is a silent `try?`, and the consequence of one failing quietly is somebody
// unable to save their work with no idea why.
//
// Covered by the licence suite in tests/run-tests.sh, which drives the exact
// sequence performSetup(.rebuild) performs around deleting the prefix.

import Foundation

func licenseStashDir() -> String {
    let d = appSupport() + "/license"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
func slcFiles(in dir: String) -> [String] {
    (((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.lowercased().hasSuffix(".slc") }).sorted()
}

// WHERE SAI LOOKS FOR THE CERTIFICATE CHANGED BETWEEN BUILDS:
//   - older Ver.2 builds read it from the folder holding sai2.exe;
//   - the 2026-07-12 "Technical Preview Major Renovated" build reads it from a
//     `settings` folder instead (the renovation moved config/licence paths).
// Guessing wrong looks exactly like an invalid licence — SAI just refuses to
// save, with no hint that the file is in the wrong folder. A certificate is
// 128 bytes, so write BOTH and let whichever build you run find its own.
var licenseDirs: [String] { [prefixSAIDir, "\(prefixSAIDir)/settings"] }

func installedLicenseName() -> String? {
    for d in licenseDirs { if let f = slcFiles(in: d).first { return f } }
    return nil
}

// ---- which SAI build is installed? -----------------------------------------
// SAI ships its own changelog, `history.txt`, newest entry first, with the build
// date as a bare `YYYY-MM-DD` line. Reading that beats guessing from the folder
// name (users rename them) or the exe size (changes every release).
//
// We report the DATE and nothing more. It is tempting to infer the branch —
// "Major Renovated" vs "Technical Preview Stable" — from a cutoff date, but that
// is wrong: SYSTEMAX updates BOTH branches, so a Stable build released after the
// renovated one carries a later date and would be misclassified. There is no
// date at which one branch starts and the other stops.
//
// It doesn't matter anyway: the licence is written to every location SAI might
// read, so nothing depends on knowing the branch. A build date is a fact we can
// show without it going stale; a branch label would be a guess that rots.
func licenseLocations() -> [String] {
    licenseDirs.filter { !slcFiles(in: $0).isEmpty }
}
func licenseLocationSummary() -> String {
    let have = licenseLocations()
    if have.count == licenseDirs.count { return "in both locations (works on old and new SAI builds)" }
    if have.isEmpty { return "not installed" }
    return have.contains(prefixSAIDir) ? "only next to sai2.exe (older builds)"
                                       : "only in settings/ (Major Renovated build)"
}

@discardableResult
func installLicenseFile(_ src: String) -> Bool {
    let name = (src as NSString).lastPathComponent
    var wroteAny = false
    for dir in licenseDirs {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dst = "\(dir)/\(name)"
        if dst == src { wroteAny = true; continue }        // already in place
        try? FileManager.default.removeItem(atPath: dst)
        if (try? FileManager.default.copyItem(atPath: src, toPath: dst)) != nil { wroteAny = true }
    }
    guard wroteAny else { return false }
    // Keep a copy so a rebuild can put it back — unless we are restoring FROM
    // the stash, in which case src IS that copy. Removing it first then deleted
    // the source of the copy that follows, and every restore silently emptied
    // the stash: the licence survived that rebuild because it had just been
    // written into the prefix, but the copy the uninstall dialog promises to be
    // holding ("so a future reinstall can restore it") was gone. Both calls are
    // `try?`, so nothing said so.
    let stash = "\(licenseStashDir())/\(name)"
    let same = URL(fileURLWithPath: src).standardizedFileURL
        == URL(fileURLWithPath: stash).standardizedFileURL
    if !same {
        try? FileManager.default.removeItem(atPath: stash)
        try? FileManager.default.copyItem(atPath: src, toPath: stash)
    }
    return true
}
/// Put every stashed certificate back after a rebuild. Best-effort and silent:
/// a rebuilt prefix has a new System ID, so the old cert may no longer validate —
/// the UI says so rather than pretending the restore guarantees activation.
func restoreStashedLicenses() {
    let stash = licenseStashDir()
    guard !slcFiles(in: stash).isEmpty else { return }
    for f in slcFiles(in: stash) {
        installLicenseFile("\(stash)/\(f)")      // writes every location SAI might read
    }
}

/// Notice a certificate that is already sitting in the SAI folder the user just
/// picked, and take it under management. Returns its name if there was one.
///
/// Such a file is one they already own, so making them find it again through
/// "Install…" is asking a question we can answer ourselves. It also closes two
/// real gaps, because until now setup's `cp -R` was the only thing that moved
/// it:
///
///   - a plain copy lands it wherever it happened to sit in the SOURCE layout,
///     which may not be where the installed build reads from. SAI's response to
///     a certificate in the wrong folder is to silently refuse to save — the
///     same symptom as an invalid licence, with nothing pointing at the cause.
///   - it never reached the stash, so the next rebuild lost it.
///
/// Deliberately does NOT write into the prefix unless SAI is already there:
/// creating prefix folders before setup has run would leave a half-made prefix
/// behind if the user stops here. The stash alone is enough — performSetup ends
/// with restoreStashedLicenses(), which writes every location SAI might read.
@discardableResult
func adoptLicenseFromSourceFolder(_ src: String) -> String? {
    // Look in both places SAI itself uses, since the user's folder mirrors one.
    let found = [src, "\(src)/settings"]
        .compactMap { d in slcFiles(in: d).first.map { "\(d)/\($0)" } }
        .first
    guard let path = found else { return nil }
    let name = (path as NSString).lastPathComponent
    let stash = "\(licenseStashDir())/\(name)"
    if !FileManager.default.fileExists(atPath: stash) {
        try? FileManager.default.copyItem(atPath: path, toPath: stash)
    }
    if saiInstalledInPrefix() { _ = installLicenseFile(path) }
    return name
}

// ---- setup / repair / rebuild ----------------------------------------------

// WinePatch.swift — puts the IOSurface Mac driver into the user's Wine while
// Retina mode is on, and the original back when it is off. The decision is in
// WinePatchCore.swift; this file is the files.
//
// Only ever touches lib/wine/x86_64-unix/winemac.so of the Wine we run, and
// only when it is byte-for-byte a file we know (see WinePatchCore).

import Foundation
import CryptoKit

/// Bundled patched driver (copied in by make-app.sh). nil when running unbundled.
func bundledPatchedDriver() -> String? {
    guard let res = Bundle.main.resourcePath else { return nil }
    let p = res + "/winemac-iosurface-11.16.so"
    return FileManager.default.fileExists(atPath: p) ? p : nil
}

/// winemac.so of the Wine whose `wine` binary is at `wine`.
func wineMacDriverPath(_ wine: String) -> String {
    let bin = (wine as NSString).deletingLastPathComponent          // .../wine/bin
    return ((bin as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
}

func sha256Hex(_ path: String) -> String? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

/// Copy `src` over `dst` by writing next to it and renaming. A Wine process
/// that already has the old file loaded keeps its copy (the old inode); only
/// processes started afterwards load the new one.
@discardableResult
func atomicReplace(_ dst: String, with src: String) -> Bool {
    let tmp = dst + ".saipp-tmp"
    let fm = FileManager.default
    try? fm.removeItem(atPath: tmp)
    guard (try? fm.copyItem(atPath: src, toPath: tmp)) != nil else { return false }
    if rename(tmp, dst) != 0 { try? fm.removeItem(atPath: tmp); return false }
    return true
}

/// What the app does before SAI starts. Returns true if the driver changed, so
/// the caller restarts Wine first (every Wine process should use one driver).
@discardableResult
func syncWineMacDriver(_ wine: String, wantPatched: Bool) -> Bool {
    guard !wine.isEmpty else { return false }
    let drv = wineMacDriverPath(wine)
    let backup = drv + ".orig-11.16"
    let action = WinePatchCore.action(current: sha256Hex(drv), backup: sha256Hex(backup),
                                      wantPatched: wantPatched)
    switch action {
    case .none:
        return false
    case .unknownWine:
        wlog("wine driver: not patching, this Wine is not the known Staging 11.16 build")
        return false
    case .cannotRestore:
        wlog("wine driver: patched driver installed but no original backup, leaving it")
        return false
    case .install:
        guard let patched = bundledPatchedDriver(),
              sha256Hex(patched) == WinePatchCore.patchedSHA256 else {
            wlog("wine driver: bundled patched driver missing or damaged, not patching")
            return false
        }
        // The backup is written from the installed ORIGINAL only (the core
        // guarantees that), and never overwritten once it is valid.
        if sha256Hex(backup) != WinePatchCore.originalSHA256 {
            try? FileManager.default.removeItem(atPath: backup)
            guard (try? FileManager.default.copyItem(atPath: drv, toPath: backup)) != nil else {
                wlog("wine driver: could not back up the original, not patching")
                return false
            }
        }
        let ok = atomicReplace(drv, with: patched)
        wlog("wine driver: IOSurface patch \(ok ? "installed" : "FAILED to install")")
        return ok
    case .restore:
        let ok = atomicReplace(drv, with: backup)
        wlog("wine driver: original \(ok ? "restored" : "FAILED to restore")")
        return ok
    }
}

// WinePatchCore.swift — when to swap Wine's Mac driver for our IOSurface build.
//
// Why (RETINA-LAG-FINDINGS.md, issue #39): Wine 11.16's Mac driver hands macOS
// a new CGImage of the whole window on every update, and macOS re-draws and
// colour-converts it on the CPU. With "Sharp text on Retina screens" that made
// SAI's main thread 68% busy while drawing. Upstream Wine fixed it (commit
// b77a5f9b60, after 11.21); wine-patch/ holds that change backported to
// Wine Staging 11.16 as a rebuilt winemac.so. Measured: idle 55% -> 9%.
//
// The driver must match its Wine exactly, so files are identified by SHA-256,
// never by version string or size.
//
// THE TRAP: the backup must only ever hold the ORIGINAL driver. Backing up
// whatever is installed would, on a second install (or after a manual swap),
// back up our own patched file and lose the original for good. Install
// therefore happens only when the installed file IS the original, and the
// backup is written from that file.
//
// No AppKit, no file access: the tests compile this file on its own.

import Foundation

enum WineDriverAction: Equatable {
    /// Nothing to do: already as wanted, or no Wine.
    case none
    /// Back up the installed original, then put the patched driver in place.
    case install
    /// Put the backed-up original back.
    case restore
    /// The installed driver is neither ours nor the known original (another
    /// Wine version, or a different build). Leave it alone.
    case unknownWine
    /// The patched driver is installed but no valid original backup exists.
    /// Leave it: patched is better than broken.
    case cannotRestore
}

enum WinePatchCore {
    /// Gcenx Wine Staging 11.16, lib/wine/x86_64-unix/winemac.so as shipped.
    static let originalSHA256 = "d37656b78dfbc9b2734acdd2c2e2f68051e423836bdfd484f4336103754793fa"
    /// wine-patch/winemac-iosurface-11.16.so.
    static let patchedSHA256  = "d5eb1e715010b86791d84403f1db49f56576e06d83d9faf18027d65b3397e1c7"

    /// - current: SHA-256 of the installed winemac.so, nil if there is none.
    /// - backup: SHA-256 of the backup file, nil if there is none.
    /// - wantPatched: the patched driver is wanted (Retina mode is on).
    static func action(current: String?, backup: String?, wantPatched: Bool) -> WineDriverAction {
        guard let cur = current?.lowercased() else { return .none }
        let isOriginal = cur == originalSHA256, isPatched = cur == patchedSHA256
        if wantPatched {
            if isPatched { return .none }
            return isOriginal ? .install : .unknownWine
        }
        if isOriginal { return .none }
        if isPatched {
            return backup?.lowercased() == originalSHA256 ? .restore : .cannotRestore
        }
        return .none          // someone else's Wine, and nothing of ours to undo
    }
}

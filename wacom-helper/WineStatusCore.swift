// WineStatusCore.swift — which Wine the user has, whether it has the fix for
// the Retina drawing lag (issue #39), and what "Update Wine" should install.
//
// The fix is Wine commit b77a5f9b60 (IOSurface window updates). It was merged
// after Wine 11.21, so the first release with it is expected to be 11.22.
// Until then, Wine Staging 11.16 can get it from our patched driver
// (WinePatchCore.swift, wine-patch/).
//
// No AppKit, no network, no files: the tests compile this file on its own.

import Foundation

struct WineVersion: Comparable, Equatable {
    let major: Int, minor: Int
    static func < (a: WineVersion, b: WineVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }
    var text: String { "\(major).\(minor)" }

    /// "wine-11.16 (Staging)" or a release tag like "11.22" -> 11.16 / 11.22.
    /// Anything else (rc builds, garbage) -> nil.
    static func parse(_ s: String) -> WineVersion? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("wine-") { t.removeFirst(5) }
        let head = t.split(separator: " ").first.map(String.init) ?? t
        let parts = head.split(separator: ".")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return WineVersion(major: a, minor: b)
    }
}

enum WineFixState: Equatable {
    case notInstalled
    /// Wine itself has the fix (11.22 or newer).
    case fixedUpstream(WineVersion)
    /// Wine Staging 11.16 with our patched driver.
    case patched
    /// Wine Staging 11.16 as shipped: our patch can be added.
    case patchable
    /// Any other Wine: no fix; "Update Wine" applies.
    case needsUpdate(WineVersion?)
}

enum WineStatusCore {
    /// First Wine release expected to contain the fix. Check when 11.22 ships.
    static let firstFixed = WineVersion(major: 11, minor: 22)
    static let patchBase = WineVersion(major: 11, minor: 16)
    static let patchBaseURL =
        "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.16/wine-staging-11.16-osx64.tar.xz"

    /// - version: `wine --version` output, nil if no Wine.
    /// - driverSHA: SHA-256 of its lib/wine/x86_64-unix/winemac.so.
    static func state(version: String?, driverSHA: String?) -> WineFixState {
        guard let raw = version else { return .notInstalled }
        let v = WineVersion.parse(raw)
        if let v = v, v >= firstFixed { return .fixedUpstream(v) }
        // Identify 11.16 by its driver bytes, not only its version string: a
        // different 11.16 build (another packager) must not get our patch.
        switch driverSHA?.lowercased() {
        case WinePatchCore.patchedSHA256?:  return .patched
        case WinePatchCore.originalSHA256?: return .patchable
        default:                            return .needsUpdate(v)
        }
    }

    /// What "Update Wine" installs: the newest Gcenx Wine Staging release that
    /// has the fix, if any is out; otherwise 11.16, to be patched.
    /// - releases: (tag, staging .tar.xz download URL) from Gcenx's GitHub.
    static func updateTarget(releases: [(tag: String, url: String)]) -> (version: WineVersion, url: String, patch: Bool) {
        let fixed = releases.compactMap { r -> (WineVersion, String)? in
            guard let v = WineVersion.parse(r.tag), v >= firstFixed else { return nil }
            return (v, r.url)
        }.max { $0.0 < $1.0 }
        if let f = fixed { return (f.0, f.1, false) }
        return (patchBase, patchBaseURL, true)
    }
}

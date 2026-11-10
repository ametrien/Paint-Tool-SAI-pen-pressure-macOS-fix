// WineStatusCore.swift — which Wine the user has, whether it has the fix for
// the Retina drawing lag (issue #39), and what "Update Wine" should install.
//
// The fix is Wine commit b77a5f9b60 (IOSurface window updates). It was merged
// after Wine 11.21, so the first release with it is expected to be 11.22, and
// every later one (12.0-rc1, 12.0, ...) has it too.
// Until then, Wine Staging 11.16 can get it from our patched driver
// (WinePatchCore.swift, wine-patch/).
//
// No AppKit, no network, no files: the tests compile this file on its own.

import Foundation

struct WineVersion: Comparable, Equatable {
    let major: Int, minor: Int
    /// Release candidate number ("12.0-rc1" -> 1). nil for a normal release.
    var rc: Int? = nil
    /// The packager's rebuild number (Gcenx tags like "11.6_1" -> 1). 0 if none.
    var rev: Int = 0

    /// 11.21 < 11.22 < 11.22_1 < 12.0-rc1 < 12.0-rc2 < 12.0.
    static func < (a: WineVersion, b: WineVersion) -> Bool {
        (a.major, a.minor, a.rc ?? Int.max, a.rev) < (b.major, b.minor, b.rc ?? Int.max, b.rev)
    }
    var text: String { "\(major).\(minor)" + (rc.map { "-rc\($0)" } ?? "") }

    /// "wine-11.16 (Staging)", or a release tag like "11.22", "12.0-rc1" or
    /// "11.6_1". Anything else -> nil.
    ///
    /// THE TRAP: release candidates and rebuilds must parse. Wine's yearly
    /// release starts as "12.0-rc1", which is NEWER than every 11.x. When this
    /// returned nil for it, a Wine that has the fix was shown as "can lag", and
    /// Update Wine offered to go back to 11.16. A rebuild tag ("11.22_1") was
    /// skipped the same way, so a fixed release could be passed over.
    static func parse(_ s: String) -> WineVersion? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("wine-") { t.removeFirst(5) }
        var head = t.split(separator: " ").first.map(String.init) ?? t
        func number(_ x: Substring) -> Int? {
            (!x.isEmpty && x.allSatisfy { $0.isASCII && $0.isNumber }) ? Int(x) : nil
        }
        // "_1": a rebuild of the same Wine by the packager.
        var rev = 0
        if let i = head.lastIndex(of: "_") {
            guard let n = number(head[head.index(after: i)...]) else { return nil }
            rev = n
            head = String(head[..<i])
        }
        // "-rc1": a release candidate.
        var rc: Int? = nil
        if let r = head.range(of: "-rc") {
            guard let n = number(head[r.upperBound...]) else { return nil }
            rc = n
            head = String(head[..<r.lowerBound])
        }
        let parts = head.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = number(parts[0]), let b = number(parts[1]) else { return nil }
        return WineVersion(major: a, minor: b, rc: rc, rev: rev)
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

    /// What Setup's "Install Wine" and Advanced's "Update Wine" install: the
    /// newest Gcenx Wine Staging release that has the fix, if any is out;
    /// otherwise 11.16, to be patched.
    ///
    /// THE TRAP: Setup must use this too, never "the newest build". The newest
    /// one can be a Wine without the fix that our patch does not fit (11.17 to
    /// 11.21), and then a new user starts with drawing that lags with sharp
    /// text, and is told to install an older Wine a minute after installing.
    /// An empty list (offline, GitHub not answering) gives 11.16 plus patch.
    /// - releases: (tag, staging .tar.xz download URL) from Gcenx's GitHub.
    static func updateTarget(releases: [(tag: String, url: String)]) -> (version: WineVersion, url: String, patch: Bool) {
        let fixed = releases.compactMap { r -> (WineVersion, String)? in
            guard let v = WineVersion.parse(r.tag), v >= firstFixed else { return nil }
            return (v, r.url)
        }.max { $0.0 < $1.0 }
        if let f = fixed { return (f.0, f.1, false) }
        return (patchBase, patchBaseURL, true)
    }

    /// The shell command that runs install-wine.sh for one chosen build, for
    /// the Terminal route. The command ends up inside an AppleScript string in
    /// double quotes, so a URL with a quote or a backslash in it is not passed
    /// on (the script then picks a build by itself).
    static func installCommand(script: String, url: String?) -> String {
        let run = "bash '\(script)'"
        guard let u = url, u.hasPrefix("https://"),
              !u.contains(where: { "'\"\\ $`\n".contains($0) }) else { return run }
        return "WINE_URL='\(u)' \(run)"
    }
}

// WinePatchTests.swift — unit tests for WinePatchCore (swapping Wine's Mac driver).

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

@main
struct WinePatchTests {
    static func main() {
        print("WinePatchCore tests:")
        let orig = WinePatchCore.originalSHA256, ours = WinePatchCore.patchedSHA256
        let other = String(repeating: "ab", count: 32)
        func act(_ c: String?, _ b: String?, _ w: Bool) -> WineDriverAction {
            WinePatchCore.action(current: c, backup: b, wantPatched: w)
        }

        // Retina on: patch only the exact original.
        expect(act(orig, nil, true) == .install, "on: the known 11.16 original gets patched")
        expect(act(ours, orig, true) == .none, "on: already patched, nothing to do")
        expect(act(other, nil, true) == .unknownWine, "on: any other Wine is left alone")
        expect(act(nil, nil, true) == .none, "on: no Wine installed, nothing to do")
        expect(act(orig.uppercased(), nil, true) == .install, "hashes compare case-insensitively")

        // THE TRAP: a second install must never happen on a patched file,
        // because the backup is written from the installed file.
        expect(act(ours, nil, true) != .install && act(ours, ours, true) != .install,
               "on: never 'install' over our own file (it would become the backup)")

        // Retina off: undo only our own change, and only with a valid backup.
        expect(act(ours, orig, false) == .restore, "off: patched + original backup -> restore")
        expect(act(ours, nil, false) == .cannotRestore, "off: no backup -> leave the patched driver")
        expect(act(ours, ours, false) == .cannotRestore,
               "off: a backup that is not the original is never restored")
        expect(act(ours, other, false) == .cannotRestore, "off: a foreign backup is never restored")
        expect(act(orig, orig, false) == .none, "off: already original, nothing to do")
        expect(act(other, orig, false) == .none, "off: another Wine is never touched")

        // --- WineStatusCore -----------------------------------------------
        print("WineStatusCore tests:")
        let v = WineVersion.parse
        expect(v("wine-11.16 (Staging)") == WineVersion(major: 11, minor: 16), "version: wine --version is parsed")
        expect(v("11.22") == WineVersion(major: 11, minor: 22), "version: a release tag is parsed")
        expect(v("11.9")! < v("11.10")!, "version: 11.9 < 11.10 (numbers, not text)")
        expect(v("garbage") == nil && v("") == nil && v("11") == nil && v("11.22.1") == nil
               && v("11.x") == nil && v("11.22-rc") == nil && v("11.22-rcx") == nil
               && v("11.22_") == nil && v("11.22_x") == nil && v("-rc1") == nil && v(".5") == nil,
               "version: odd strings are not guessed")

        // THE TRAP: release candidates. Wine's yearly release starts as
        // "12.0-rc1", newer than every 11.x. Parsed as nil, a Wine with the fix
        // was shown as "can lag" and Update Wine offered to go back to 11.16.
        expect(v("wine-12.0-rc1 (Staging)") == WineVersion(major: 12, minor: 0, rc: 1),
               "version: wine --version of a release candidate is parsed")
        expect(v("12.0-rc1") == WineVersion(major: 12, minor: 0, rc: 1), "version: a release candidate tag is parsed")
        expect(v("12.0-rc1")!.text == "12.0-rc1" && v("11.22")!.text == "11.22", "version: shown as Wine writes it")
        expect(v("11.22")! < v("12.0-rc1")!, "version: 12.0-rc1 is newer than 11.22")
        expect(v("12.0-rc1")! < v("12.0-rc2")! && v("12.0-rc9")! < v("12.0-rc10")!, "version: rc numbers in order")
        expect(v("12.0-rc6")! < v("12.0")!, "version: the release is newer than its candidates")
        expect(v("12.0")! < v("12.1")! && v("12.0-rc1")! != v("12.0")!, "version: 12.0 < 12.1, and rc1 is not 12.0")
        // Gcenx rebuilds a release under a tag like "11.6_1".
        expect(v("11.6_1") == WineVersion(major: 11, minor: 6, rev: 1), "version: a rebuild tag is parsed")
        expect(v("11.22")! < v("11.22_1")! && v("11.22_1")! < v("11.23")!, "version: a rebuild sits after its release")
        expect(v("12.0-rc1_1") == WineVersion(major: 12, minor: 0, rc: 1, rev: 1), "version: a rebuilt candidate")

        func st(_ ver: String?, _ sha: String?) -> WineFixState { WineStatusCore.state(version: ver, driverSHA: sha) }
        expect(st(nil, nil) == .notInstalled, "state: no Wine")
        expect(st("wine-11.22 (Staging)", other) == .fixedUpstream(v("11.22")!), "state: 11.22 has the fix itself")
        expect(st("wine-12.0 (Staging)", other) == .fixedUpstream(v("12.0")!), "state: newer majors too")
        expect(st("wine-11.16 (Staging)", ours) == .patched, "state: 11.16 with our driver")
        expect(st("wine-11.16 (Staging)", orig) == .patchable, "state: 11.16 as shipped can be patched")
        // THE TRAP: a different 11.16 build must not be offered our patch.
        expect(st("wine-11.16 (Staging)", other) == .needsUpdate(v("11.16")),
               "state: an 11.16 with an unknown driver is not patchable")
        expect(st("wine-11.21 (Staging)", other) == .needsUpdate(v("11.21")), "state: 11.21 needs an update")
        // THE TRAP: these have the fix. needsUpdate here means "drawing can lag"
        // on screen, sharp text off by default, and an offer of an older Wine.
        expect(st("wine-12.0-rc1 (Staging)", other) == .fixedUpstream(v("12.0-rc1")!),
               "state: 12.0-rc1 has the fix itself")
        expect(st("wine-12.0-rc4 (Staging)", orig) == .fixedUpstream(v("12.0-rc4")!),
               "state: a release candidate is never offered our 11.16 patch")
        expect(st("wine-11.0-rc3 (Staging)", other) == .needsUpdate(v("11.0-rc3")),
               "state: an old release candidate (before the fix) needs an update")
        expect(st("wine-11.22-rc1", other) == .needsUpdate(v("11.22-rc1")),
               "state: a candidate OF the first fixed release does not count as fixed")

        let none: [(tag: String, url: String)] = [("11.20", "u20"), ("11.21", "u21")]
        let t1 = WineStatusCore.updateTarget(releases: none)
        expect(t1.version == v("11.16")! && t1.patch && t1.url == WineStatusCore.patchBaseURL,
               "update: no fixed release yet -> 11.16 plus our patch")
        let t2 = WineStatusCore.updateTarget(releases: none + [("11.23", "u23"), ("11.22", "u22")])
        expect(t2.version == v("11.23")! && !t2.patch && t2.url == "u23",
               "update: the newest fixed release wins, no patch")
        let t3 = WineStatusCore.updateTarget(releases: [("11.22-rc1", "x"), ("nonsense", "y")])
        expect(t3.patch, "update: tags that are not versions, or are before the fix, are ignored")

        // THE TRAP: what Setup installs for a new user. On 2026-11-10 Gcenx's
        // list looked like this, newest first, and "take the newest" gave
        // 11.21: no fix, and our patch does not fit it.
        let today: [(tag: String, url: String)] = [("11.21", "u21"), ("11.20", "u20"), ("11.18", "u18"),
            ("11.17", "u17"), ("11.16", "u16"), ("11.6_1", "u6"), ("11.0_1", "u0")]
        let t4 = WineStatusCore.updateTarget(releases: today)
        expect(t4.url == WineStatusCore.patchBaseURL && t4.patch && t4.version == v("11.16")!,
               "install: with no fixed Wine out, a new user gets 11.16 plus our patch, not the newest")
        expect(t4.url != "u21", "install: never the newest build just because it is the newest")
        let t5 = WineStatusCore.updateTarget(releases: [])
        expect(t5.url == WineStatusCore.patchBaseURL && t5.patch,
               "install: offline (no release list) still gives 11.16 plus our patch")
        // December: the first release candidate is the newest build.
        let t6 = WineStatusCore.updateTarget(releases: [("12.0-rc1", "urc1")] + today)
        expect(t6.url == "urc1" && !t6.patch && t6.version == v("12.0-rc1")!,
               "install: 12.0-rc1 has the fix, so it is installed, not 11.16")
        let t7 = WineStatusCore.updateTarget(releases: [("12.0-rc1", "urc1"), ("11.22", "u22")] + today)
        expect(t7.url == "urc1" && !t7.patch, "install: 12.0-rc1 wins over 11.22")
        let t8 = WineStatusCore.updateTarget(releases: [("12.0-rc2", "urc2"), ("12.0", "u120"), ("12.0-rc1", "urc1")])
        expect(t8.url == "u120", "install: the release wins over its candidates, whatever the order")
        let t9 = WineStatusCore.updateTarget(releases: [("11.22", "u22"), ("11.22_1", "u22b")] + today)
        expect(t9.url == "u22b" && !t9.patch, "install: a rebuild of a fixed release wins over the first build")

        // The Terminal route gets the same build as the in-app install.
        let ic = WineStatusCore.installCommand
        expect(ic("/A B/install-wine.sh", WineStatusCore.patchBaseURL)
               == "WINE_URL='\(WineStatusCore.patchBaseURL)' bash '/A B/install-wine.sh'",
               "terminal: the chosen build is passed to the script")
        expect(ic("/x.sh", nil) == "bash '/x.sh'", "terminal: no build chosen, the script runs as before")
        // The command sits inside an AppleScript string in double quotes.
        for bad in ["https://a/b'c", "https://a/b\"c", "https://a/b\\c", "https://a/$(x)", "https://a/`x`",
                    "https://a/b c", "http://a/b", "file:///a"] {
            expect(ic("/x.sh", bad) == "bash '/x.sh'", "terminal: an unsafe URL is not passed on (\(bad))")
        }

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("All WinePatchCore tests passed.")
    }
}

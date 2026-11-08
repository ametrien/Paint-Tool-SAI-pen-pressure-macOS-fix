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
        expect(v("wine-11.0-rc3") == nil && v("garbage") == nil, "version: odd strings are not guessed")
        expect(v("11.9")! < v("11.10")!, "version: 11.9 < 11.10 (numbers, not text)")

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

        let none: [(tag: String, url: String)] = [("11.20", "u20"), ("11.21", "u21")]
        let t1 = WineStatusCore.updateTarget(releases: none)
        expect(t1.version == v("11.16")! && t1.patch && t1.url == WineStatusCore.patchBaseURL,
               "update: no fixed release yet -> 11.16 plus our patch")
        let t2 = WineStatusCore.updateTarget(releases: none + [("11.23", "u23"), ("11.22", "u22")])
        expect(t2.version == v("11.23")! && !t2.patch && t2.url == "u23",
               "update: the newest fixed release wins, no patch")
        let t3 = WineStatusCore.updateTarget(releases: [("11.22-rc1", "x"), ("nonsense", "y")])
        expect(t3.patch, "update: tags that are not plain versions are ignored")

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("All WinePatchCore tests passed.")
    }
}

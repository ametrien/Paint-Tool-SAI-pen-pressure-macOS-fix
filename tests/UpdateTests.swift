// UpdateTests.swift — unit tests for UpdateCore: the three questions that decide
// whether the app may replace itself with a file from the internet.
//
// Run:  bash tests/run-tests.sh
//
// Every case here is something that was wrong at some point today: a check that
// looked like security and wasn't, a legitimate update refused, and a marker one
// copy of the app left for another to trip over.

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String,
            file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

let slug = "ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix"

func newer(_ a: String, _ b: String) -> Bool {
    func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

@main
struct UpdateTests {
    static func main() {

        print("UpdateCore tests:")

        // --- where the file came from -----------------------------------------
        expect(isOurReleaseURL("https://github.com/\(slug)/releases/download/v0.3.3/SAI-Pen-Pressure-v0.3.3.zip", slug: slug),
               "source: our own release asset")
        expect(isOurReleaseURL("https://objects.githubusercontent.com/github-production-release-asset/1/2", slug: slug),
               "source: the host GitHub redirects the download to")
        expect(!isOurReleaseURL("http://github.com/\(slug)/releases/download/v0.3.3/x.zip", slug: slug),
               "source: plain http is refused")
        expect(!isOurReleaseURL("https://example.com/\(slug)/releases/download/v0.3.3/x.zip", slug: slug),
               "source: another host is refused")
        expect(!isOurReleaseURL("https://github.com.example.com/\(slug)/releases/download/v1/x.zip", slug: slug),
               "source: a lookalike host is refused")
        expect(!isOurReleaseURL("https://github.com/someone/else/releases/download/v1.0/x.zip", slug: slug),
               "source: another repository's release is refused")
        // Owning the path is free, so appearing in it proves nothing.
        expect(!isOurReleaseURL("https://github.com/evil/repo/releases/download/v1/\(slug).zip", slug: slug),
               "source: our name inside someone else's path is refused")
        expect(!isOurReleaseURL("not a url at all", slug: slug), "source: nonsense is refused")

        // --- is it actually newer ---------------------------------------------
        let pkg = { (v: String) in UpdatePackage(appPath: "/x", version: v, bundleID: "app.saipenpressure.mac") }
        expect(verifyUpdate(pkg("0.3.4"), currentVersion: "0.3.3", isNewer: newer) == nil,
               "version: newer is accepted")
        expect(verifyUpdate(pkg("0.3.3"), currentVersion: "0.3.3", isNewer: newer) != nil,
               "version: the same version is refused")
        expect(verifyUpdate(pkg("0.1.0"), currentVersion: "0.3.3", isNewer: newer) != nil,
               "version: a downgrade is refused")
        // A different identifier is no longer a refusal: it costs everyone their
        // Input Monitoring grant, which is worth logging, not blocking.
        let renamed = UpdatePackage(appPath: "/x", version: "0.4.0", bundleID: "something.else")
        expect(verifyUpdate(renamed, currentVersion: "0.3.3", isNewer: newer) == nil,
               "version: a renamed build is still installable")

        // --- whose marker is this ---------------------------------------------
        let me = "/Applications/SAI Pen Pressure.app"
        expect(readUpdateMarker(nil, ourPath: me, ageSeconds: 0) == .none, "marker: no file, nothing to say")
        expect(readUpdateMarker("  \n", ourPath: me, ageSeconds: 0) == .none, "marker: empty file, nothing to say")
        expect(readUpdateMarker("0.3.3\n\(me)", ourPath: me, ageSeconds: 1) == .ours(from: "0.3.3"),
               "marker: ours, and it remembers what we came from")
        // Written by a build from before the marker carried an owner.
        expect(readUpdateMarker("0.3.2", ourPath: me, ageSeconds: 1) == .ours(from: "0.3.2"),
               "marker: an old marker with no owner is treated as ours")
        expect(readUpdateMarker("0.0.1\n/Users/x/Desktop/Copy.app", ourPath: me, ageSeconds: 5) == .theirs,
               "marker: another copy's marker is left alone")
        expect(readUpdateMarker("0.0.1\n/Users/x/Desktop/Copy.app", ourPath: me, ageSeconds: 7200) == .abandoned,
               "marker: ...but not forever")

        print(failures == 0 ? "UpdateCore: all passed" : "UpdateCore: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

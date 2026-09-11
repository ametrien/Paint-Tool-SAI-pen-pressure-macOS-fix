// UpdateCore.swift — the PURE logic of the self-update, extracted so it can be
// tested without a network, a bundle, or a window.
//
// The app replaces itself from a file it fetched over the internet. Three
// questions decide whether that is safe, and all three are deterministic:
// where did it come from, is it actually newer, and whose marker is this that
// says an update just happened. Each of them has already been wrong once, which
// is why they live here rather than inline (tests/UpdateTests.swift).
//
// The I/O — downloading, unpacking, verifying the signature, swapping the
// bundle — stays in Updates.swift.

import Foundation

/// Why an update was refused. A type of its own rather than a bare string,
/// because Swift's Result wants an Error and because every one of these ends up
/// in front of a person.
struct UpdateProblem: Error { let reason: String }

struct UpdatePackage {
    let appPath: String     // the .app we just unpacked
    let version: String
    let bundleID: String
}

/// Is this download coming from OUR releases, rather than somewhere that merely
/// answered the phone?
///
/// This is the check that carries the weight, and it took a wrong turn first.
/// The original guard compared the bundle identifier inside the downloaded app
/// against our own — which defends against nothing, because the identifier
/// travels INSIDE the file: anyone able to hand us a different archive is able
/// to write any identifier they like into it. What it did do was refuse a
/// legitimate update the first time the identifier legitimately changed, which
/// is how it was caught.
///
/// The real anchor is where the file comes from: the URL is handed to us by the
/// GitHub API for one fixed repository, over TLS. So require exactly that shape
/// — https, github.com itself, and a path under this repository's releases.
/// Matching on "contains the slug" would be no check at all, since an attacker
/// owns every inch of their own path.
func isOurReleaseURL(_ raw: String, slug: String) -> Bool {
    guard let u = URLComponents(string: raw),
          u.scheme?.lowercased() == "https",
          let host = u.host?.lowercased() else { return false }
    // github.com serves the asset; objects.githubusercontent.com is where it
    // redirects, and URLSession follows that on its own.
    if host == "github.com" { return u.path.hasPrefix("/\(slug)/releases/download/") }
    return host == "objects.githubusercontent.com"
}

/// Everything else that must be true before we overwrite ourselves with this.
/// Returns nil when it is safe, or the reason it isn't.
func verifyUpdate(_ pkg: UpdatePackage, currentVersion: String,
                  isNewer: (String, String) -> Bool) -> String? {
    guard isNewer(pkg.version, currentVersion) else {
        return "that download is \(pkg.version), which is not newer than \(currentVersion)"
    }
    return nil
}

/// What to do with the "an update just happened" marker found at launch.
///
/// The marker says which version we came from AND which bundle did it, because
/// Application Support is shared by every copy of this app on the machine. With
/// only the version in it, a second copy that happened to start next picked up
/// somebody else's marker and announced an update it had never performed,
/// permission warning and all. Seen within a minute of the feature existing.
enum UpdateMarker: Equatable {
    case none                    // nothing to say
    case ours(from: String)      // we updated: announce it
    case theirs                  // another copy's: leave it where it is
    case abandoned               // theirs, but long past anyone coming for it
}

func readUpdateMarker(_ text: String?, ourPath: String, ageSeconds: Double,
                      abandonedAfter: Double = 3600) -> UpdateMarker {
    guard let raw = text, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
    let parts = raw.split(separator: "\n", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    let from = parts.first ?? ""
    let who = parts.count > 1 ? parts[1] : ""
    // A marker with no owner comes from a build that predates this field. It is
    // ours by default: the old behaviour, rather than a silent no-op.
    if who.isEmpty || who == ourPath { return .ours(from: from) }
    return ageSeconds > abandonedAfter ? .abandoned : .theirs
}

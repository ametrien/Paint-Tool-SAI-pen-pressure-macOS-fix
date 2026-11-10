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

// ---------------------------------------------------------------------------
// When GitHub does not answer
//
// The check and the download are plain web requests, and GitHub sometimes
// answers them with "503 Service Unavailable" for a few seconds. Before this,
// one such answer was the end of it: the check stayed silent until the next
// launch, and "Update now" failed on the spot.
// ---------------------------------------------------------------------------

enum UpdateFetchOutcome: Equatable {
    case ok        // got it
    case retry     // a passing problem on their side or on the way: try again
    case giveUp    // trying again right away will not change the answer
}

/// What one answer means. `status` is the HTTP status, nil when there was no
/// answer at all (offline, timed out, connection dropped).
///
/// THE TRAP: 403 and 429 are GitHub saying "too many requests, wait". Asking
/// again a few seconds later is exactly what not to do, and 404 will not turn
/// into a file. Only "no answer" and the 5xx family are worth another try.
func updateFetchOutcome(status: Int?) -> UpdateFetchOutcome {
    guard let s = status else { return .retry }
    if (200..<300).contains(s) { return .ok }
    if s == 408 || (500..<600).contains(s) { return .retry }
    return .giveUp
}

/// Waits before the 2nd, 3rd and 4th try, in seconds. Four tries in all, about
/// 17 s at most: long enough for a hiccup, short enough to still be watching.
let updateRetryDelays: [Double] = [2, 5, 10]

/// How long to wait before trying again after try number `attempt` (1-based)
/// ended with `status`. nil means stop: it worked, it cannot work, or the
/// tries are used up.
func updateRetryDelay(afterAttempt attempt: Int, status: Int?,
                      delays: [Double] = updateRetryDelays) -> Double? {
    guard updateFetchOutcome(status: status) == .retry,
          attempt >= 1, attempt <= delays.count else { return nil }
    return delays[attempt - 1]
}

/// Why it did not work, for a person. Ends without a full stop: callers put it
/// into their own sentence.
func updateFailureText(status: Int?) -> String {
    guard let s = status else { return "no answer from GitHub. Check your internet connection" }
    if (200..<300).contains(s) { return "GitHub's answer could not be read" }
    if s == 403 || s == 429 { return "GitHub asks to wait a little before trying again (error \(s))" }
    if (500..<600).contains(s) { return "GitHub is having trouble right now (error \(s))" }
    return "GitHub answered with error \(s)"
}

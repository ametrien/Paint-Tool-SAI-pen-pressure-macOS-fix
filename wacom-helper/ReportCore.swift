// ReportCore.swift — the PURE part of preparing a report for a stranger.
//
// Copy problem report exists so someone can paste their situation into a public
// issue without hunting for facts. That makes everything in it public by
// design, and the paths in it carried the account name: a report from a machine
// whose user is called "anna.petrova" published that, in a tracker, to answer a
// question about a tablet.
//
// Nothing diagnostic is lost by removing it. "~/SAI2-pressure" says exactly
// what "/Users/anna.petrova/SAI2-pressure" says, and the one fact that matters
// about a SAI folder is where it sits relative to home, not who is logged in.
//
// Deliberately not behind a setting. A checkbox defaults to one state, and
// whichever is chosen is wrong for somebody: on by default and the report looks
// doctored, off by default and the people who most need the redaction are
// exactly the ones who will not find the switch.

import Foundation

enum ReportCore {

    /// Replace the home directory with `~`, and any other account name under
    /// /Users with a placeholder.
    ///
    /// Two passes because they catch different things. The first is exact and
    /// safe: the literal home path becomes `~`. The second catches paths
    /// belonging to somebody else, or to this user written some other way — a
    /// SAI folder under /Users/someone-else/Shared, for instance.
    ///
    /// THE TRAP, and the reason the account name is never matched on its own:
    /// an account called "admin", "art" or "mac" appears inside ordinary words
    /// and ordinary paths. Replacing the bare name would turn "administrator"
    /// into "<user>istrator" and mangle the very log lines the report exists to
    /// carry. Only a name in the position of a /Users component is replaced.
    static func redactHome(_ text: String, home: String, placeholder: String = "<user>") -> String {
        var out = text
        // Pass 1: the exact home path. Longest and most specific, so it goes
        // first — otherwise pass 2 would rewrite its /Users component and leave
        // a half-redacted path that no longer matches anything.
        if !home.isEmpty, home != "/" {
            out = out.replacingOccurrences(of: home, with: "~")
        }
        // Pass 2: /Users/<anyone>/ -> /Users/<user>/ , plus the bare /Users/<anyone>
        // at the very end of a path. "Shared" is a real system directory, not a
        // person, and redacting it would lose a genuine distinction.
        guard let re = try? NSRegularExpression(pattern: "/Users/([^/\\s\"']+)") else { return out }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += (name == "Shared") ? ns.substring(with: m.range) : "/Users/\(placeholder)"
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

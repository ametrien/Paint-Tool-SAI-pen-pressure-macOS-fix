// ReportTests.swift — the account name must not travel with a bug report.
//
// Run:  bash tests/run-tests.sh

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String,
            file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

@main
struct ReportTests {
    static func main() {
        print("ReportCore tests:")

        let home = "/Users/anna.petrova"

        // The ordinary case: the paths a report is actually made of.
        let report = """
        Prefix: /Users/anna.petrova/SAI2-pressure  (exists: true)
        SAI source: /Users/anna.petrova/Downloads/sai2-64bit
        wintab32.dll: true
        """
        let clean = ReportCore.redactHome(report, home: home)
        expect(!clean.contains("anna.petrova"), "redact: the account name is gone")
        expect(clean.contains("~/SAI2-pressure"), "redact: the prefix still reads as ~/SAI2-pressure")
        expect(clean.contains("~/Downloads/sai2-64bit"), "redact: and the SAI folder keeps its shape")
        expect(clean.contains("wintab32.dll: true"), "redact: everything else is untouched")

        // Somebody ELSE's path, or this user's written another way. The home
        // pass cannot catch these, which is why there is a second pass.
        let other = ReportCore.redactHome("SAI source: /Users/other.person/art/sai2", home: home)
        expect(!other.contains("other.person"), "redact: another account under /Users goes too")
        expect(other.contains("/Users/<user>/art/sai2"), "redact: and the rest of that path survives")

        // THE TRAP, and the reason the bare name is never matched: an account
        // called "admin", "art" or "mac" is a substring of ordinary words. A
        // replace-the-name-everywhere implementation passes every case above
        // and quietly corrupts the log lines the report exists to carry.
        let wordy = ReportCore.redactHome(
            "user admin ran administrator tools; prefix /Users/admin/SAI2-pressure",
            home: "/Users/admin")
        expect(wordy.contains("administrator tools"),
               "redact: a name that is also a word is not butchered mid-sentence")
        expect(wordy.contains("user admin ran"),
               "redact: nor is it removed where it is not a path")
        expect(wordy.contains("~/SAI2-pressure"),
               "redact: while the path it appears in is still redacted")

        // /Users/Shared is a real system directory, not a person. Redacting it
        // would lose a genuine distinction: "in the shared folder" and "in
        // somebody's home" are different answers to where SAI was installed.
        let shared = ReportCore.redactHome("SAI source: /Users/Shared/sai2", home: home)
        expect(shared.contains("/Users/Shared/sai2"), "redact: /Users/Shared is left alone")

        // Degenerate inputs must not eat the text. An empty home, or "/",
        // would otherwise match everywhere and turn the report into tildes.
        expect(ReportCore.redactHome("hello /Users/x", home: "") == "hello /Users/<user>",
               "redact: an empty home does not swallow the report")
        expect(ReportCore.redactHome("a / b", home: "/") == "a / b",
               "redact: home of / is ignored")
        expect(ReportCore.redactHome("", home: home) == "", "redact: empty input stays empty")

        // A report with nothing personal in it must come back identical.
        let plain = "macOS: 26.6.2\nWine: wine-11.16 (Staging) [x86_64]"
        expect(ReportCore.redactHome(plain, home: home) == plain,
               "redact: a report with no paths is returned unchanged")

        print(failures == 0 ? "ReportCore: all passed" : "ReportCore: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

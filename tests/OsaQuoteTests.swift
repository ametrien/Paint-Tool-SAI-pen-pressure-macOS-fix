// OsaQuoteTests.swift — every dialog the app builds must compile, and say
// exactly what it was given. Run against the real /usr/bin/osascript.
//
// Why: alertUser built its AppleScript with Swift's debugDescription, which
// writes an apostrophe as \'. AppleScript has no such escape, the script did
// not compile, and the dialog never appeared: 25 of the app's 56 messages,
// "Couldn't repair the bridge" among them (OsaQuote.swift has the story).
//
// No test here puts anything on the screen. Text goes through `return`, which
// osascript prints, and dialogs are compiled inside `if false`, never run.

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

/// The \( ) values in a line of Swift that do NOT sit inside an osaQuote(...)
/// call. Parentheses are matched by counting, which is enough for this code.
func rawInterpolations(_ line: String) -> [String] {
    let c = Array(line)
    /// Index just past the ")" that closes the "(" at `open`.
    func close(_ open: Int) -> Int {
        var depth = 0, j = open
        while j < c.count {
            if c[j] == "(" { depth += 1 }
            if c[j] == ")" { depth -= 1; if depth == 0 { return j + 1 } }
            j += 1
        }
        return c.count
    }
    let quote = Array("osaQuote(")
    var out: [String] = []
    var i = 0
    while i < c.count {
        if i + quote.count <= c.count, Array(c[i..<i + quote.count]) == quote {
            i = close(i + quote.count - 1)          // skip the whole call
        } else if c[i] == "\\", i + 1 < c.count, c[i + 1] == "(" {
            let end = close(i + 1)
            let inner = String(c[(i + 2)..<max(i + 2, end - 1)])
            if inner.hasPrefix("osaQuote(") { i = end; continue }
            out.append(inner)
            i = end
        } else { i += 1 }
    }
    return out
}

/// Run a script made of these lines through osascript.
func osascript(_ lines: [String]) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = lines.flatMap { ["-e", $0] }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    try! p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

/// Does this dialog script compile? Wrapped in `if false` so it is never shown.
func compiles(_ script: String) -> (Bool, String) {
    let r = osascript(["if false then", script, "end if"])
    return (r.status == 0, r.err)
}

@main
struct OsaQuoteTests {
    static func main() {
        print("osaQuote / alertScript tests (real osascript):")

        // 1. Whatever goes in comes back out, character for character.
        let everyPrintableASCII = String((32...126).map { Character(Unicode.Scalar($0)!) })
        let samples: [(String, String)] = [
            ("apostrophe", "Couldn't repair the bridge."),
            ("double quotes", "Pick the folder named \"SAI Ver.2\"."),
            ("backslashes", "C:\\Program Files\\SAI\\sai2.exe and a lone \\"),
            ("both, back to back", "\\\"\\'\"'\\"),
            ("line breaks and a tab", "one\n\ntwo\tthree"),
            ("non-ASCII", "Reinstall… → Repair ✅ Привет 日本語 🖊"),
            ("every printable ASCII character", everyPrintableASCII),
            ("empty", ""),
        ]
        for (what, s) in samples {
            let r = osascript(["return " + osaQuote(s)])
            // osascript ends what it prints with one newline of its own.
            expect(r.status == 0 && r.out == s + "\n", "round trip: \(what)")
            if r.status != 0 || r.out != s + "\n" {
                print("        sent: \(s.debugDescription)\n        got:  \(r.out.debugDescription) \(r.err)")
            }
        }
        // A NUL cannot travel in a process argument; it is dropped, not left
        // to cut the script short.
        let nul = osascript(["return " + osaQuote("a\0b")])
        expect(nul.status == 0 && nul.out == "ab\n", "a NUL is dropped and the rest survives")

        // 2. The dialogs exactly as alertUser builds them. These are the
        // messages a user pressing Repair could get; before the fix, every one
        // with an apostrophe failed to compile and was never seen.
        let messages = [
            "Couldn't repair the bridge.\n\nTry Reinstall… → Repair, which rebuilds this part of the prefix from scratch.",
            "The bridge was already complete. Nothing needed fixing.\n\nIf pressure still doesn't reach SAI, try Test pen in the Pen tab.",
            "Fixed.\n\nWine had been loading its own wintab32; it now loads ours. Restart SAI for this to take effect.",
            "SAI is installed, but the Wine setting that makes it load the pressure driver could not be written.\n\nPressure won't work until it is.",
            "That folder doesn't contain sai2.exe:\n\n/Users/someone/SAI \"2\"\n\nPick the folder that DIRECTLY contains sai2.exe.",
        ]
        for m in messages {
            let (ok, err) = compiles(alertScript(m))
            expect(ok, "dialog compiles: \(m.prefix(40).replacingOccurrences(of: "\n", with: " "))…")
            if !ok { print("        \(err)") }
        }
        // And every printable character inside a real dialog, not just `return`.
        expect(compiles(alertScript(everyPrintableASCII)).0, "dialog compiles with every printable ASCII character in it")

        // 3. The shape alertUser shows: one OK button, the text in quotes.
        expect(alertScript("x") == "display dialog \"x\" buttons {\"OK\"} with icon note",
               "alertScript: one message, one OK button")

        // 4. Every dialog in the app's source, not only alertUser. The tests
        // above prove osaQuote is right; this proves nobody went around it.
        // THE TRAP it guards: a dialog that drops a value straight into the
        // AppleScript text. With debugDescription an apostrophe broke it (25
        // dialogs never shown); with plain \(value) a double quote or a
        // backslash does the same, and a path, a file name or an error text can
        // hold either. So in a line with a dialog, every value goes through
        // osaQuote, apart from the few listed here that cannot hold a quote.
        let safeRaw: Set<String> = [
            "d + 1", "v + 1",        // numbers (PenUI)
            "currentVersion()",      // "0.3.18"
            "name",                  // this app's own name (Input Monitoring)
            "items",                 // a list built from osaQuote (SetupUI)
            "buttons",               // a fixed AppleScript list (Updates)
        ]
        let src = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("wacom-helper")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: src.path))?
            .filter { $0.hasSuffix(".swift") && $0 != "OsaQuote.swift" }.sorted() ?? []
        var dialogLines = 0
        for f in files {
            let text = (try? String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)) ?? ""
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains("display dialog") || line.contains("choose from list") {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                dialogLines += 1
                let at = "\(f):\(i + 1)"
                expect(!line.contains("debugDescription"), "source: \(at) builds no dialog with debugDescription")
                for raw in rawInterpolations(line) where !safeRaw.contains(raw) {
                    expect(false, "source: \(at) puts \\(\(raw)) into a dialog without osaQuote")
                }
            }
        }
        // Not vacuous: the scan must have found the app's dialogs.
        expect(dialogLines >= 20, "source: the scan saw the app's dialogs (\(dialogLines) lines)")

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("All osaQuote tests passed.")
    }
}

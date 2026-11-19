// OsaQuote.swift — text for inside an AppleScript, and the script of the one
// dialog every message of this app goes through (alertUser).
//
// A file of its own so the tests can compile it alone and hand what it builds
// to the real osascript (tests/OsaQuoteTests.swift).

import Foundation

/// A string literal for inside an osa() script. AppleScript only escapes
/// backslash and double quote; newlines are fine inside its quotes. A NUL
/// cannot travel in a process argument at all, so it is dropped rather than
/// left to cut the script short.
///
/// THE TRAP this replaced in alertUser: Swift's `debugDescription`. It looks
/// like the same thing, a quoted and escaped string, but it writes an
/// apostrophe as \' and AppleScript has no such escape. The script does not
/// compile ("Expected “"” but found unknown token"), osascript exits with an
/// error, osa() returns nil, and the dialog simply never appears. Every
/// message with "can't", "doesn't" or "Couldn't" in it was lost that way, 25
/// of the 56 the app had, "Couldn't repair the bridge" among them: a user
/// pressed Repair, saw nothing at all, and gave up (reported on YouTube
/// 2026-11-17, found 2026-11-19). Only "Fixed." ever showed, because it has
/// no apostrophe, so on a machine where Repair works nothing looked wrong.
func osaQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// The script alertUser runs: one message, one OK button.
func alertScript(_ msg: String) -> String {
    "display dialog \(osaQuote(msg)) buttons {\"OK\"} with icon note"
}

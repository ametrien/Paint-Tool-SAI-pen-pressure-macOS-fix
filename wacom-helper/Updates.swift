// Updates.swift — noticing that a newer release exists, and pointing at it.
//
// Moved out of main.swift unchanged. Deliberately just a check and a link: the
// app does not update itself, because an app that replaces its own binary while
// holding an Input Monitoring grant is how that grant gets silently revoked.

import AppKit
import Foundation

extension SetupController {

    func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
    /// true if a > b, comparing dotted numeric versions ("0.1.4" > "0.1.3")
    func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
    // Ask GitHub for the newest release. Read-only, anonymous, ~1 request per
    // launch; silently does nothing if offline.
    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let d = data,
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let tag = j["tag_name"] as? String else { return }
            let notes = (j["body"] as? String) ?? ""
            DispatchQueue.main.async { self.showUpdateStatus(tag: tag, notes: notes) }
        }.resume()
    }
    func showUpdateStatus(tag: String, notes: String) {
        latestTag = tag; latestNotes = notes
        guard updateLabel != nil else { return }
        if isNewer(tag, than: currentVersion()) {
            // Keep the label SHORT — a release-notes teaser here overflowed the
            // row. The first meaningful line goes in the tooltip instead (with
            // markdown markers stripped); full notes are behind the button.
            let first = notes.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(">") } ?? ""
            let teaser = first.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            updateLabel.stringValue = "· Update available: \(tag)"
            updateLabel.toolTip = teaser.isEmpty ? nil : teaser
            updateLabel.textColor = .controlAccentColor
            updateBtn.isHidden = false
        } else {
            updateLabel.stringValue = "· up to date"
            updateLabel.toolTip = nil
            updateLabel.textColor = .tertiaryLabelColor
            updateBtn.isHidden = true
        }
    }
    @objc func openReleasePage() {
        let s = latestTag.map { "https://github.com/\(repoSlug)/releases/tag/\($0)" }
            ?? "https://github.com/\(repoSlug)/releases/latest"
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

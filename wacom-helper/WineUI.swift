// WineUI.swift — the Wine part of Advanced: which Wine is installed, whether
// it has the fix for the Retina drawing lag (issue #39), and the buttons to add
// or remove our patch or update Wine. Logic: WineStatusCore / WinePatchCore.

import AppKit

/// Present when the user removed our patch. Missing means: patch wanted.
func winePatchOffFile() -> String { appSupport() + "/wine-patch-off.txt" }
func winePatchWanted() -> Bool { !FileManager.default.fileExists(atPath: winePatchOffFile()) }
func setWinePatchWanted(_ on: Bool) {
    if on { try? FileManager.default.removeItem(atPath: winePatchOffFile()) }
    else { try? "".write(toFile: winePatchOffFile(), atomically: true, encoding: .utf8) }
}

/// `wine --version`, e.g. "wine-11.16 (Staging)". nil if it cannot run.
func wineVersionString(_ wine: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: wine)
    p.arguments = ["--version"]
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (s?.isEmpty ?? true) ? nil : s
}

func currentWineFixState() -> (WineFixState, String?) {
    guard let wine = wineBin() else { return (.notInstalled, nil) }
    let ver = wineVersionString(wine)
    return (WineStatusCore.state(version: ver, driverSHA: sha256Hex(wineMacDriverPath(wine))), ver)
}

/// Gcenx's Wine Staging releases: (tag, staging download URL).
func fetchGcenxStagingReleases() -> [(tag: String, url: String)] {
    guard let url = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=40"),
          let data = try? Data(contentsOf: url),
          let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return list.compactMap { r in
        guard let tag = r["tag_name"] as? String,
              let assets = r["assets"] as? [[String: Any]],
              let a = assets.first(where: { ($0["name"] as? String) == "wine-staging-\(tag)-osx64.tar.xz" }),
              let u = a["browser_download_url"] as? String else { return nil }
        return (tag, u)
    }
}

extension SetupController {

    func buildWineSection() -> NSStackView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        box.addArrangedSubview(lbl("Wine", 11, bold: true))
        wineStatusLabel = lbl("Checking…", 11, color: .secondaryLabelColor)
        wineStatusLabel.preferredMaxLayoutWidth = rowWidth
        wineStatusLabel.lineBreakMode = .byWordWrapping
        wineStatusLabel.usesSingleLineMode = false
        box.addArrangedSubview(wineStatusLabel)
        wineActionBtn = NSButton(title: "", target: self, action: #selector(wineActionTapped))
        wineActionBtn.bezelStyle = .rounded
        wineActionBtn.controlSize = .small
        wineActionBtn.isHidden = true
        box.addArrangedSubview(wineActionBtn)
        refreshWineSection()
        return box
    }

    /// `wine --version` takes a moment under Rosetta, so off the main thread.
    func refreshWineSection() {
        guard wineStatusLabel != nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let (state, ver) = currentWineFixState()
            DispatchQueue.main.async { self.showWineState(state, ver) }
        }
    }

    private func showWineState(_ state: WineFixState, _ ver: String?) {
        let name = ver ?? "Wine"
        var text = "", button: String? = nil
        switch state {
        case .notInstalled:
            text = "No Wine installed yet. Install it on the Setup tab."
        case .fixedUpstream:
            text = "\(name). This Wine has the fix for smooth drawing with sharp text built in."
        case .patched:
            text = "\(name) with our patch: Wine's Mac display driver with the IOSurface fix "
                 + "(Wine commit b77a5f9b60, backported). Smooth drawing with sharp text."
            button = "Remove patch"
        case .patchable:
            text = "\(name), original. Our patch for smooth drawing with sharp text can be added."
            button = "Add patch"
        case .needsUpdate:
            text = "\(name). Drawing with sharp text can lag with this Wine."
            button = "Update Wine for sharper, faster drawing"
        }
        if case .patchable = state, !winePatchWanted() { text += " You removed it earlier." }
        wineStatusLabel.stringValue = text
        wineActionBtn.title = button ?? ""
        wineActionBtn.isHidden = button == nil
        wineActionBtn.isEnabled = wineProc == nil
        applyLayout()
    }

    @objc func wineActionTapped() {
        let (state, _) = currentWineFixState()
        switch state {
        case .patched:   changePatch(wanted: false)
        case .patchable: changePatch(wanted: true)
        case .needsUpdate: updateWine()
        default: refreshWineSection()
        }
    }

    /// Add or remove our patch. Applied now if SAI is closed, otherwise the
    /// next time SAI starts (prepareDisplaySettingsForLaunch).
    private func changePatch(wanted: Bool) {
        setWinePatchWanted(wanted)
        guard let wine = wineBin() else { return }
        if saiProcessRunning() {
            alertUser("Done. It applies the next time SAI starts.")
        } else if syncWineMacDriver(wine, wantPatched: wanted) {
            stopWineForPrefix(wine)
        }
        refreshWineSection()
    }

    private func updateWine() {
        guard !saiProcessRunning() else {
            alertUser("Please quit SAI first (save your work), then press Update Wine again.")
            return
        }
        wineActionBtn.isEnabled = false
        wineStatusLabel.stringValue = "Looking for the newest Wine…"
        DispatchQueue.global(qos: .userInitiated).async {
            let target = WineStatusCore.updateTarget(releases: fetchGcenxStagingReleases())
            let current = wineBin().flatMap(wineVersionString).flatMap(WineVersion.parse)
            DispatchQueue.main.async { self.confirmAndInstall(target, current: current) }
        }
    }

    private func confirmAndInstall(_ t: (version: WineVersion, url: String, patch: Bool), current: WineVersion?) {
        // Say plainly when this goes BACK to an older Wine: until Wine ships the
        // fix (11.22), the only fixed Wine we have is 11.16 with our patch.
        let older = current.map { t.version < $0 } ?? false
        let what: String
        if t.patch && older {
            what = "an older Wine (Wine Staging \(t.version.text), you have \(current!.text)) with our patch, "
                 + "because Wine with the fix built in is not out yet"
        } else if t.patch {
            what = "Wine Staging \(t.version.text) with our patch"
        } else {
            what = "Wine Staging \(t.version.text), which has the fix built in"
        }
        let a = NSAlert()
        a.messageText = older ? "Install an older Wine with the fix?" : "Update Wine?"
        a.informativeText = "This installs \(what). It is a download of about 190 MB.\n\n"
            + "Your current Wine goes to the Trash, so you can put it back. "
            + "Your SAI, licence, brushes and settings stay as they are."
        a.addButton(withTitle: "Update Wine")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { refreshWineSection(); return }
        guard !saiProcessRunning() else { alertUser("Please quit SAI first."); refreshWineSection(); return }

        if let wine = wineBin() { stopWineForPrefix(wine) }
        let app = "/Applications/Wine Staging.app"
        if FileManager.default.fileExists(atPath: app) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: app), resultingItemURL: nil) }
            catch { alertUser("Couldn't move the current Wine to the Trash:\n\n\(error.localizedDescription)"); refreshWineSection(); return }
        }
        setWinePatchWanted(true)
        afterWineInstall = { [weak self] in
            if t.patch, let wine = wineBin() { syncWineMacDriver(wine, wantPatched: true) }
            self?.refreshWineSection()
        }
        installWineInApp(url: t.url)
    }
}

/// Does the Wine SAI runs have the fix for the Retina lag? Our patched driver
/// (or the original 11.16 that the launch will patch, if the patch is wanted),
/// or Wine 11.22+. Read from files plus `wine --version`; call off the main
/// thread when possible.
func wineHasRetinaFix() -> Bool {
    switch currentWineFixState().0 {
    case .fixedUpstream, .patched: return true
    case .patchable: return winePatchWanted() && bundledPatchedDriver() != nil
    default: return false
    }
}

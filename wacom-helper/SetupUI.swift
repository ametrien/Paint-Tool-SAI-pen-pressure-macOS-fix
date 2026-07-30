// SetupUI.swift — the Setup tab and the first-run flow: choosing a SAI folder,
// installing Wine, granting Input Monitoring, reinstalling, uninstalling.
//
// Moved out of main.swift unchanged. It is the largest tab because it is the one
// somebody uses once and then never again, and every step of it can fail in a way
// that needs explaining rather than a spinner.
//
// The destructive half of the uninstall is performUninstall, kept separate from
// the dialogs above it so the tests can drive it against a throwaway install.

import AppKit
import Foundation

extension SetupController {

    @objc func updateSAITapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Update"
        panel.message = "Choose the folder containing the newer sai2.exe"
        if let cur = installedSrcPath() {
            panel.directoryURL = URL(fileURLWithPath: (cur as NSString).deletingLastPathComponent)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if saiWindowIsOpen() {
            alertUser("Quit SAI first — its files are in use while it is running.")
            return
        }
        if let problem = updateSAIFromFolder(url.path) {
            alertUser(problem)
        } else {
            alertUser("SAI updated.\n\nYour licence, brushes and preferences were kept.")
        }
        refresh(); applyLayout()
    }
    @objc func extraTapped(_ sender: NSButton) {
        reqs[sender.tag].extraAction?()
    }
    @objc func fixTapped(_ sender: NSButton) {
        reqs[sender.tag].fix()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }
    /// Find folders that actually contain sai2.exe, so we can OFFER the right
    /// one instead of dropping the user into a blank file picker and hoping they
    /// remember where they unzipped it. Spotlight first (instant, whole disk),
    /// with a shallow scan of the usual places as a fallback when Spotlight is
    /// disabled or the folder isn't indexed.
    func findSAIFolders() -> [String] {
        var out: [String] = []
        func consider(_ dir: String) {
            guard FileManager.default.fileExists(atPath: "\(dir)/sai2.exe") else { return }
            guard !dir.hasPrefix(appPrefix) else { return }     // our own copy: a destination, not a source
            guard !out.contains(dir) else { return }
            out.append(dir)
        }
        for line in runCapture("/usr/bin/mdfind", ["kMDItemFSName == 'sai2.exe'"]).split(separator: "\n") {
            consider((String(line) as NSString).deletingLastPathComponent)
        }
        if out.isEmpty {
            let home = NSHomeDirectory()
            let roots = ["\(home)/Documents", "\(home)/Downloads", "\(home)/Desktop",
                         "\(home)/Applications", "/Applications"]
            for root in roots {
                consider(root)
                for sub in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []) {
                    consider("\(root)/\(sub)")
                }
            }
        }
        return out
    }
    func chooseSAI() {
        // Suggest what we found before opening a picker.
        let found = findSAIFolders()
        if let best = found.first {
            let shown = (best as NSString).abbreviatingWithTildeInPath
            if found.count == 1 {
                let c = osa("button returned of (display dialog \"Found SAI here:\n\n\(shown)\n\nUse this folder?\" buttons {\"Choose another…\", \"Use this folder\"} default button \"Use this folder\" with icon note)")
                if c == "Use this folder" { adoptSAIFolder(best); return }
            } else {
                // several installs — let the user pick which one
                let items = found.map { "\"\(($0 as NSString).abbreviatingWithTildeInPath)\"" }.joined(separator: ", ")
                if let picked = osa("choose from list {\(items)} with prompt \"Found more than one SAI folder — pick the one to use:\" OK button name \"Use this folder\" cancel button name \"Choose another…\""),
                   picked != "false" {
                    let full = found.first { ($0 as NSString).abbreviatingWithTildeInPath == picked }
                    if let f = full { adoptSAIFolder(f); return }
                }
            }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        // Open the picker somewhere useful rather than at the last-used folder.
        panel.directoryURL = URL(fileURLWithPath: (found.first as NSString?)?.deletingLastPathComponent
                                 ?? savedSAIPath().map { ($0 as NSString).deletingLastPathComponent }
                                 ?? NSHomeDirectory() + "/Documents")
        panel.prompt = "Choose"
        panel.message = found.isEmpty
            ? "Select your SAI Ver.2 folder — the one that directly contains sai2.exe"
            : "Select your SAI Ver.2 folder (we found one at \((found[0] as NSString).abbreviatingWithTildeInPath))"
        if panel.runModal() == .OK, let url = panel.url {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("sai2.exe").path) {
                adoptSAIFolder(url.path)
            } else {
                alertUser("That folder doesn't contain sai2.exe. Pick the folder that directly contains sai2.exe.")
            }
        }
        refresh()
    }
    /// Record a chosen source folder and, if the prefix already holds a
    /// different build, offer to apply it now. Picking a folder used to change
    /// nothing but a label (issue #11).
    func adoptSAIFolder(_ path: String) {
        saveSAIPath(path)
        // If their folder already holds a certificate, say so now rather than
        // leaving them to hunt for a file they clearly already have.
        if let lic = adoptLicenseFromSourceFolder(path) {
            let where_ = installedLicenseName() != nil
                ? "It's installed in every folder SAI might read it from, and saved so a rebuild can restore it."
                : "Saved — it will be installed automatically when SAI is set up."
            alertUser("License detected ✅\n\n\(lic) was already in the folder you picked.\n\n\(where_)")
        }
        if saiInstalledInPrefix() && prefixIsStale() {
            let c = osa("button returned of (display dialog \"Copy this SAI into the Wine prefix now?\n\nSAI runs from a copy inside \(( prefixSAIDir as NSString).abbreviatingWithTildeInPath). Until it's copied, SAI will keep running the previous version.\" buttons {\"Later\", \"Reinstall now\"} default button \"Reinstall now\" with icon note)")
            if c == "Reinstall now" { doReinstall(mode: .repair) }
        }
        refresh()
    }
    /// Is this copy ad-hoc signed? If so macOS will never prompt for Input
    /// Monitoring, because there's no durable identity to attach the grant to.
    /// `codesign` reports on stderr, hence the merged capture.
    func isAdHocSigned() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dv", Bundle.main.bundlePath]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return out.contains("adhoc")
    }
    /// Make macOS ask again. Once Input Monitoring has been answered for an app
    /// identity, `IOHIDRequestAccess` silently returns the cached answer forever
    /// and the only route left is hunting the app down in a file picker.
    /// `tccutil reset` clears the entry so the native prompt fires again.
    ///
    /// Deliberately narrow and deliberately not silent: it targets THIS app's
    /// bundle id only (never a blanket reset), it can only REMOVE a grant —
    /// never add one, you still approve in System Settings — and it asks first.
    @objc func resetOwnPermission() {
        let bid = Bundle.main.bundleIdentifier ?? "com.runasharp.saipenpressure"
        let c = osa("button returned of (display dialog \"Make macOS ask for Input Monitoring again?\n\nThis clears only this app's own permission entry (\(bid)) so the system prompt reappears — much quicker than adding the app by hand.\n\nIt cannot grant anything: you still approve it in System Settings. The app will relaunch.\" buttons {\"Cancel\", \"Reset & ask again\"} default button \"Reset & ask again\" with icon caution)")
        guard c == "Reset & ask again" else { return }
        _ = runCapture("/usr/bin/tccutil", ["reset", "ListenEvent", bid])
        // The prompt only fires on a fresh launch, so bounce ourselves.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 1; open '\(Bundle.main.bundlePath)'"]
        try? p.run()
        exit(0)
    }
    /// Granting Input Monitoring means finding this app in a file picker, which
    /// is the fiddliest step in the whole setup. Do the finding FOR the user:
    /// open the right Settings pane, reveal the app in Finder so it can be
    /// dragged straight in, and put its path on the clipboard to paste.
    @objc func grantInputMonitoring() {
        // Keep this DUMB and linear: request, open the right Settings pane, help
        // the user find the app. An earlier version branched into "reset and
        // relaunch" first and returned early — which meant Grant stopped opening
        // Settings at all and just bounced the app back to this same dialog.
        // Opening Settings is the step that actually works; never skip it.
        // ("Ask again" still exists as its own button for the genuinely stuck
        // case, but it is not on the path of the normal Grant flow.)
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)      // no-op if already answered
        let appPath = Bundle.main.bundlePath
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appPath, forType: .string)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
        alertUser("""
        Turn ON "SAI Pen Pressure" in the list that just opened.

        If it isn't listed, click + and either:
          • drag "SAI Pen Pressure" from the Finder window that just opened, or
          • press ⇧⌘G and paste (⌘V) — the path is already on your clipboard.

        This app's path:
        \(appPath)

        Tip: if you see several "SAI Pen Pressure" entries from older builds, turn off or remove the old ones — only the one at the path above is this build.
        """)
    }
    @objc func openOfficialSAISite() {
        if let u = URL(string: SetupController.saiOfficialURL) { NSWorkspace.shared.open(u) }
    }
    func chooseLicense() {
        if installedLicenseName() == nil {
            let c = osa("button returned of (display dialog \"You need your own SAI license certificate (.slc).\n\nPaintTool SAI is commercial software by SYSTEMAX. Buy a license and download your .slc from the official site — this app is NOT affiliated with SYSTEMAX, and it cannot supply, generate or activate a license for you.\n\nIt only copies a .slc you already own into the folder SAI reads.\" buttons {\"Cancel\", \"Open official site\", \"I have my .slc\"} default button \"I have my .slc\" with icon note)")
            if c == "Open official site" { openOfficialSAISite(); return }
            if c != "I have my .slc" { return }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        panel.message = "Select your SAI license certificate (.slc)"
        // .slc isn't a registered system type, so filter loosely and validate the
        // extension ourselves — a hard UTType filter can grey out the real file.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "slc" else {
            alertUser("That isn't a .slc certificate:\n\n\(url.lastPathComponent)\n\nPick the sai-*.slc file you downloaded from SYSTEMAX.")
            return
        }
        if installLicenseFile(url.path) {
            // Show the REAL paths. SAI reads the certificate from a different
            // folder depending on the build, so "installed" alone doesn't tell
            // you whether the build you run will actually find it.
            let paths = licenseLocations()
                .map { "  \(($0 as NSString).abbreviatingWithTildeInPath)/\(url.lastPathComponent)" }
                .joined(separator: "\n")
            alertUser("""
            License installed — copied to both places SAI might read it:

            \(paths)

            Older SAI builds read it next to sai2.exe; the 2026-07-12 "Major Renovated" preview reads it from settings/. Copying both means whichever build you run finds it.

            Quit SAI completely and relaunch for it to take effect (closing the window isn't enough).
            """)
        } else {
            alertUser("Couldn't copy the license into the Wine prefix. Check that \(( prefixSAIDir as NSString).abbreviatingWithTildeInPath) is writable, then try again.")
        }
        refresh()
    }
    // ---- reinstall / repair (issue #10) -------------------------------------
    func reinstallMenu() {
        guard let wine = wineBin() else {
            alertUser("Wine isn't installed yet — install it first (top row)."); return
        }
        guard savedSAIPath() != nil else { chooseSAI(); return }
        _ = wine
        let c = osa("button returned of (display dialog \"How much do you want to reinstall?\n\n• Repair — copy SAI and the pressure bridge back into the existing Wine prefix. Keeps your license and Wine settings. Try this first.\n\n• Full rebuild — delete \(( appPrefix as NSString).abbreviatingWithTildeInPath) entirely and build it from scratch. Use this if the prefix is damaged. Your license is saved and put back automatically.\" buttons {\"Cancel\", \"Full rebuild…\", \"Repair\"} default button \"Repair\" with icon caution)")
        switch c {
        case "Repair":       doReinstall(mode: .repair)
        case "Full rebuild…":
            let ok = osa("button returned of (display dialog \"Delete and rebuild \(( appPrefix as NSString).abbreviatingWithTildeInPath)?\n\nEverything in that folder is removed, including anything you put there by hand. SAI is copied in again from your source folder, and your saved license is restored.\" buttons {\"Cancel\", \"Rebuild\"} default button \"Cancel\" with icon caution)")
            if ok == "Rebuild" { doReinstall(mode: .rebuild) }
        default: break
        }
    }
    // ONE button: a true factory reset. Wipes the prefix, FORGETS every
    // remembered path, optionally removes Wine, then starts setup from zero.
    // Deliberately keeps the licence stash — re-buying a certificate is not a
    // reasonable price for "reinstall", and it's the one thing we can't recreate.
    @objc func installFromScratch() {
        let hadWine = wineBin() != nil
        let ours = wineInstalledByUs()
        var bullets = "• delete \(( appPrefix as NSString).abbreviatingWithTildeInPath) (the whole Wine prefix)\n• forget your saved SAI folder\n• forget which build was installed"
        bullets += "\n• KEEP your saved license, and put it back afterwards"
        let c = osa("button returned of (display dialog \"Reset everything and start over?\n\nThis will:\n\n\(bullets)\n\nThen it asks you to pick your SAI folder again and rebuilds from scratch. Takes about a minute.\" buttons {\"Cancel\", \"Reset everything\"} default button \"Cancel\" with icon caution)")
        guard c == "Reset everything" else { return }

        // Wine is shared with any other Windows app you run, so never remove it
        // silently. If WE installed it for SAI we say so and default to removing;
        // otherwise we default to keeping it.
        var removeWine = false
        if hadWine {
            let q = ours
                ? "Also remove Wine?\n\nThis app installed Wine Staging for SAI, so removing it should be safe. It goes to the Trash and you can reinstall it from this window anytime."
                : "Also remove Wine?\n\nWine Staging was NOT installed by this app — you may be using it for other Windows programs. Keeping it is the safe choice."
            let def = ours ? "Move Wine to Trash" : "Keep Wine"
            let w = osa("button returned of (display dialog \(q.debugDescription) buttons {\"Keep Wine\", \"Move Wine to Trash\"} default button \(def.debugDescription) with icon caution)")
            removeWine = (w == "Move Wine to Trash")
        }

        // --- wipe -------------------------------------------------------------
        try? FileManager.default.removeItem(atPath: appPrefix)
        try? FileManager.default.removeItem(atPath: appSupport() + "/config.txt")
        try? FileManager.default.removeItem(atPath: appSupport() + "/installed-src.txt")
        if removeWine {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: "/Applications/Wine Staging.app"), resultingItemURL: nil)
            try? FileManager.default.removeItem(atPath: appSupport() + "/wine-ours.txt")
        }
        refresh()

        if removeWine || wineBin() == nil {
            alertUser("Reset done. Everything was removed.\n\nInstall Wine again from this window, then pick your SAI folder and Launch — your license is saved and will be restored automatically.")
            return
        }
        // --- rebuild ----------------------------------------------------------
        chooseSAI()                                   // forgotten on purpose: ask again
        guard savedSAIPath() != nil else {
            alertUser("Reset done. Choose your SAI folder in this window whenever you're ready — your license is saved and will be restored.")
            return
        }
        doReinstall(mode: .rebuild)
    }
    /// Drive the bar across one setup step (issue #28).
    ///
    /// `wineboot` produces nothing we can parse and takes about a minute, so
    /// there is no real percentage to show. Instead the bar approaches the
    /// step's end asymptotically — fast at first, slower as it goes — and
    /// **never arrives on its own**: only the next step (or completion) moves
    /// it past `to`. So it always looks alive, and it never claims progress it
    /// hasn't actually observed. A step that overruns its estimate keeps
    /// creeping, ever more slowly, instead of sitting at 100% and lying.
    func setupStep(from: Double, to: Double, label: String, expected: Double) {
        setupTimer?.invalidate()
        wineRow.isHidden = false
        wineLabel.stringValue = label
        wineBar.value = CGFloat(from)
        applyLayout()
        let started = Date()
        setupTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.wineBar.value = CGFloat(PressureCore.setupCreep(
                from: from, to: to,
                elapsed: Date().timeIntervalSince(started), expected: expected))
        }
        RunLoop.main.add(setupTimer!, forMode: .common)   // keep ticking during menu tracking
    }
    func setupFinished(_ ok: Bool) {
        setupTimer?.invalidate(); setupTimer = nil
        wineBar.value = ok ? 1 : 0
        wineLabel.stringValue = ok ? "Done ✅" : "Setup failed."
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 2 : 4)) { [weak self] in
            self?.wineRow.isHidden = true; self?.applyLayout()
        }
    }
    /// Pull the last "NN.N%" out of a curl progress-bar chunk.
    func percent(in s: String) -> Double? {
        guard let pctIdx = s.lastIndex(of: "%") else { return nil }
        var digits = ""
        var i = pctIdx
        while i > s.startIndex {
            i = s.index(before: i)
            let c = s[i]
            if c.isNumber || c == "." { digits.insert(c, at: digits.startIndex) } else { break }
        }
        return Double(digits)
    }
    func handleWineLine(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        DispatchQueue.main.async {
            if let p = self.percent(in: t), t.contains("#") || t.hasSuffix("%") {
                self.wineBar.value = CGFloat(p / 100.0)
                self.wineLabel.stringValue = String(format: "Downloading Wine… %.1f%%", p)
            } else if t.contains("Extracting") {
                self.wineBar.value = 1; self.wineLabel.stringValue = "Extracting…"
            } else if t.contains("Installing to") {
                self.wineLabel.stringValue = "Installing to /Applications…"
            } else if t.contains("Finding the latest") {
                self.wineLabel.stringValue = "Finding the latest Wine build…"
            } else if t.contains("Done!") {
                self.wineLabel.stringValue = "Wine installed."
            }
        }
    }
    @objc func installWineInApp() {
        guard wineProc == nil else { return }
        guard let sh = Bundle.main.resourcePath.map({ "\($0)/install-wine.sh" }),
              FileManager.default.fileExists(atPath: sh) else {
            installWineViaTerminal(); return
        }
        markWineInstalledByUs()
        wineRow.isHidden = false
        wineBar.value = 0
        wineLabel.stringValue = "Starting…"
        applyLayout()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [sh]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        wineOutBuf = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self = self else { return }
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self.wineOutBuf += s
            // curl redraws its bar with \r, so split on BOTH terminators and treat
            // the trailing partial chunk as a live progress line.
            let parts = self.wineOutBuf.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            self.wineOutBuf = parts.last ?? ""
            for l in parts.dropLast() { self.handleWineLine(l) }
            self.handleWineLine(self.wineOutBuf)
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.wineProc = nil
                let ok = wineBin() != nil
                self.wineLabel.stringValue = ok ? "Wine installed ✅" : "Wine install failed — try the Terminal fallback."
                self.wineBar.value = ok ? 1 : 0
                self.refresh()
                if !ok {
                    let c = osa("button returned of (display dialog \"The automatic Wine install didn't finish.\n\nRun it in a Terminal window instead so you can see the full output?\" buttons {\"Cancel\", \"Open Terminal\"} default button \"Open Terminal\" with icon caution)")
                    if c == "Open Terminal" { installWineViaTerminal() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.wineRow.isHidden = true; self.applyLayout()
                    }
                }
            }
        }
        do { try p.run(); wineProc = p } catch {
            wineRow.isHidden = true; installWineViaTerminal()
        }
    }
    // ---- automatic setup ----------------------------------------------------
    // Walks every required step in order and does each one itself, pausing only
    // where macOS or a licence genuinely needs a human. Replaces "read five rows,
    // work out which button to press, repeat".
    @objc func autoSetup() {
        guard !autoRunning else { return }
        autoRunning = true
        autoBtn.isEnabled = false
        DispatchQueue.global().async { self.autoSteps() }
    }
    func step(_ n: Int, _ msg: String) {
        DispatchQueue.main.async { self.subtitle.stringValue = "Step \(n)/5 — \(msg)" }
    }
    /// Run a main-thread UI call from the background and wait for its result.
    func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        var out: T!
        DispatchQueue.main.sync { out = work() }
        return out
    }
    func autoSteps() {
        defer { DispatchQueue.main.async { self.autoRunning = false; self.autoBtn.isEnabled = true; self.refresh() } }

        // 1 — Wine
        if wineBin() == nil {
            step(1, "installing Wine…")
            let go = onMain { osa("button returned of (display dialog \"Automatic setup will now install Wine.\n\nIt's about a 300 MB download and runs in a Terminal window so you can watch the progress. I'll wait for it and carry on by myself when it's done.\" buttons {\"Cancel\", \"Install Wine\"} default button \"Install Wine\" with icon note)") }
            guard go == "Install Wine" else { return }
            onMain { self.markWineInstalledByUs() }
            installWineViaTerminal()
            // wait for Wine to appear (up to 20 min — it's a big download)
            var waited = 0
            while wineBin() == nil && waited < 1200 {
                Thread.sleep(forTimeInterval: 2); waited += 2
                if waited % 20 == 0 { step(1, "waiting for Wine to finish installing… (\(waited)s)") }
            }
            guard wineBin() != nil else {
                onMain { alertUser("Wine still isn't in /Applications, so automatic setup stopped here.\n\nFinish the Wine install in the Terminal window, then press 'Set up everything automatically' again — it will pick up from this step.") }
                return
            }
        }
        guard let wine = wineBin() else { return }

        // 2 — SAI source folder
        if savedSAIPath() == nil {
            step(2, "finding your SAI folder…")
            let found = onMain { self.findSAIFolders() }
            if found.count == 1 {
                let c = onMain { osa("button returned of (display dialog \"Found SAI here:\n\n\((found[0] as NSString).abbreviatingWithTildeInPath)\n\nUse this folder?\" buttons {\"Choose another…\", \"Use this folder\"} default button \"Use this folder\" with icon note)") }
                if c == "Use this folder" { onMain { saveSAIPath(found[0]) } } else { onMain { self.chooseSAI() } }
            } else {
                onMain { self.chooseSAI() }
            }
            guard savedSAIPath() != nil else {
                onMain { alertUser("Automatic setup stopped: no SAI folder chosen.\n\nRun it again whenever you're ready — it resumes from here.") }
                return
            }
        }
        guard let src = savedSAIPath() else { return }

        // 3 — build the prefix
        if !saiInstalledInPrefix() || prefixIsStale() {
            step(3, "building the Wine prefix and copying SAI… (about a minute)")
            guard performSetup(src, wine, mode: .ensure, quiet: true) else {
                onMain { alertUser("Automatic setup couldn't build the Wine prefix. Check the SAI folder and try again.") }
                return
            }
        }

        // 4 — licence
        if installedLicenseName() == nil {
            step(4, "installing your license…")
            let c = onMain { osa("button returned of (display dialog \"Do you have your SAI license file (.slc)?\n\nSAI runs and draws without it, but can't save. Licenses come from SYSTEMAX — this project is not affiliated with them and cannot provide one.\" buttons {\"Skip for now\", \"Open official site\", \"I have my .slc\"} default button \"I have my .slc\" with icon note)") }
            if c == "Open official site" { onMain { self.openOfficialSAISite() } }
            else if c == "I have my .slc" { onMain { self.chooseLicense() } }
        }

        // 5 — permission
        if !inputMonitoringGranted() {
            step(5, "granting Input Monitoring…")
            onMain { self.grantInputMonitoring() }
            var waited = 0
            while !inputMonitoringGranted() && waited < 180 {
                Thread.sleep(forTimeInterval: 2); waited += 2
            }
        }

        // done
        let ok = wineBin() != nil && saiInstalledInPrefix() && inputMonitoringGranted()
        DispatchQueue.main.async {
            self.subtitle.stringValue = ok ? "All set. Click Launch." : "Almost there — finish the red items above."
            let lic = installedLicenseName() == nil ? "\n\nNo license installed yet — SAI will run but can't save." : ""
            alertUser(ok
                ? "Setup complete.\n\nSAI is installed in \((prefixSAIDir as NSString).abbreviatingWithTildeInPath).\(lic)\n\nClick \"Launch SAI with Pressure\", then in SAI turn on Others → Options → Pen Tablet → Use WinTab API and restart SAI."
                : "Automatic setup finished what it could. The remaining red items in the window need you.\(lic)")
        }
    }
    // Remove everything this project created, and NOTHING the user brought.
    // Their SAI source folder and their original .slc are never touched — those
    // are inputs we copied FROM, not things we own.
    /// Everything the uninstall actually DELETES, with the questions already
    /// answered. Separate from the dialogs so it can be tested against a
    /// throwaway prefix — this is the most destructive path in the app, and the
    /// dialog above it makes promises ("KEPT (yours, never touched)") that only
    /// this code can keep.
    func performUninstall(keepLicense: Bool, removeWine: Bool) {
        let fm = FileManager.default
        // Stop Wine before the prefix disappears underneath it (#28), otherwise
        // the daemon lives on against deleted files and can be inherited by the
        // next launch.
        if let w = wineBin() { stopWineForPrefix(w) }
        try? fm.removeItem(atPath: appPrefix)
        for f in ["config.txt", "installed-src.txt", "devmode.txt", "wine-ours.txt",
                  "timelapse-session.txt"] {
            try? fm.removeItem(atPath: appSupport() + "/" + f)
        }
        try? fm.removeItem(atPath: appSupport() + "/recordings")
        try? fm.removeItem(atPath: appSupport() + "/bin")
        if !keepLicense { try? fm.removeItem(atPath: licenseStashDir()) }
        // NOTHING here touches the videos folder. Timelapses are the user's
        // work, they live outside our folders (~/Movies by default), and the
        // index that says which sessions belong together lives in there with
        // them — deleting either would throw away finished videos to remove an
        // installation.
        if removeWine {
            try? fm.trashItem(at: URL(fileURLWithPath: "/Applications/Wine Staging.app"),
                              resultingItemURL: nil)
        }
    }
    @objc func uninstallEverything() {
        let fm = FileManager.default
        let src = savedSAIPath()
        let srcExists = src.map { fm.fileExists(atPath: "\($0)/sai2.exe") } ?? false
        let keptLine = srcExists
            ? "\n\nKEPT (yours, never touched):\n• \((src! as NSString).abbreviatingWithTildeInPath)"
            : "\n\nYour own SAI folder is never touched."
        let c = osa("button returned of (display dialog \"Remove SAI Pen Pressure's installation?\n\nWILL BE DELETED:\n• \(( appPrefix as NSString).abbreviatingWithTildeInPath) (Wine prefix + the SAI copy inside it)\n• saved settings: chosen folder, dev mode, recordings\(keptLine)\" buttons {\"Cancel\", \"Remove\"} default button \"Cancel\" with icon caution)")
        guard c == "Remove" else { return }

        // The licence is the one thing we cannot recreate — ask before dropping it.
        var keepLicense = true
        if !slcFiles(in: licenseStashDir()).isEmpty {
            let l = osa("button returned of (display dialog \"Keep your saved license copy?\n\nWe hold a copy of \(slcFiles(in: licenseStashDir()).joined(separator: ", ")) so a future reinstall can restore it. Your ORIGINAL .slc file wherever you downloaded it is never touched either way.\" buttons {\"Delete it too\", \"Keep license\"} default button \"Keep license\" with icon note)")
            keepLicense = (l != "Delete it too")
        }

        var removeWine = false
        if wineBin() != nil {
            let ours = wineInstalledByUs()
            let q = ours
                ? "Also remove Wine?\n\nThis app installed Wine Staging for SAI, so removing it should be safe."
                : "Also remove Wine?\n\nWine Staging was NOT installed by this app — you may use it for other Windows programs. Keeping it is the safe choice."
            let def = ours ? "Move Wine to Trash" : "Keep Wine"
            removeWine = (osa("button returned of (display dialog \(q.debugDescription) buttons {\"Keep Wine\", \"Move Wine to Trash\"} default button \(def.debugDescription) with icon caution)") == "Move Wine to Trash")
        }

        performUninstall(keepLicense: keepLicense, removeWine: removeWine)
        devMode = false
        refresh()
        let licNote = keepLicense && !slcFiles(in: licenseStashDir()).isEmpty
            ? "\n\nYour license copy was kept and will be restored on the next install."
            : ""
        alertUser("Removed.\(licNote)\n\nThis app itself is still here — quit it and drag it to the Trash if you're done, or just pick your SAI folder again to reinstall.")
    }
    /// Did THIS app install Wine? Set when the user takes our "Install Wine"
    /// path, so a reset can tell "installed for SAI" from "the user's own Wine".
    func wineInstalledByUs() -> Bool {
        FileManager.default.fileExists(atPath: appSupport() + "/wine-ours.txt")
    }
    func markWineInstalledByUs() {
        try? "1".write(toFile: appSupport() + "/wine-ours.txt", atomically: true, encoding: .utf8)
    }
    func doReinstall(mode: SetupMode) {
        guard let wine = wineBin(), let src = savedSAIPath() else { refresh(); return }
        let wasRunning = running
        subtitle.stringValue = mode == .rebuild ? "Rebuilding the Wine prefix…" : "Reinstalling SAI…"
        launchBtn.isEnabled = false
        // wineboot + a full copy takes ~a minute; off the main thread so the
        // window keeps drawing instead of beachballing.
        DispatchQueue.global().async {
            // performSetup runs off the main thread, so every step report has to
            // hop back before it touches the UI.
            let ok = performSetup(src, wine, mode: mode) { from, to, label, expected in
                DispatchQueue.main.async {
                    self.setupStep(from: from, to: to, label: label, expected: expected)
                }
            }
            DispatchQueue.main.async {
                self.setupFinished(ok)
                self.running = wasRunning
                self.refresh()
                if ok {
                    let lic = installedLicenseName().map { "\n\nLicense in place: \($0)" }
                        ?? "\n\nNo license found — use Install… on the license row if you need to save."
                    alertUser("Done. SAI is installed in:\n\n\(( prefixSAIDir as NSString).abbreviatingWithTildeInPath)\(lic)")
                } else {
                    self.subtitle.stringValue = "Reinstall failed — check the SAI source folder."
                }
            }
        }
    }
    @objc func toggleDevMode(_ sender: NSMenuItem) { devMode.toggle() }
    // Uninstall Wine on request: move "Wine Staging.app" to the Trash (reversible)
    // after confirming. Deliberately leaves the Wine prefix (~/SAI2-pressure) and
    // its SAI setup + license .slc untouched — only the Wine runtime is removed.
    func uninstallWine() {
        let path = "/Applications/Wine Staging.app"
        guard FileManager.default.fileExists(atPath: path) else {
            alertUser("Wine Staging isn't in /Applications, so there's nothing to uninstall.")
            refresh(); return
        }
        let choice = osa("button returned of (display dialog \"Move 'Wine Staging.app' to the Trash?\n\nThis removes the Wine runtime. Your SAI setup and license (in ~/SAI2-pressure) are kept, and you can reinstall Wine anytime from this window.\" buttons {\"Cancel\", \"Move to Trash\"} default button \"Cancel\" with icon caution)")
        guard choice == "Move to Trash" else { refresh(); return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            alertUser("Wine was moved to the Trash. Reopen this window's Install Wine option whenever you want it back.")
        } catch {
            alertUser("Couldn't remove Wine automatically. Drag 'Wine Staging.app' from /Applications to the Trash yourself.\n\n(\(error.localizedDescription))")
        }
        refresh()
    }
    func relaunchForPermission() {
        // Tap couldn't be created — Input Monitoring isn't (yet) granted to THIS
        // app build. Guide the user to grant it, open the right Settings pane,
        // and reopen the app (macOS applies the grant on a fresh launch).
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        _ = osa("display dialog \"Couldn't read the tablet yet.\n\nIn System Settings → Privacy & Security → Input Monitoring, turn ON 'SAI Pen Pressure', then reopen this app.\" buttons {\"Reopen now\"} default button \"Reopen now\" with icon caution")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 1; open '\(Bundle.main.bundlePath)'"]
        try? p.run()
        exit(0)
    }
}

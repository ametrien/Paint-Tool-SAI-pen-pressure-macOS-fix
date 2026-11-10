// Updates.swift — noticing that a newer release exists, and installing it.
//
// The check and the download both try again when GitHub does not answer (the
// rules are in UpdateCore.swift), and when that is not enough the row says so
// and offers "Check again" and the releases page.

import AppKit
import Foundation

/// Expand a downloaded release zip and find the app inside it.
///
/// Not in UpdateCore with the rest: this one shells out and touches the disk.
/// It stays here so the pure half can be tested without either.
func unpackUpdate(zip: String, into dir: String) -> Result<UpdatePackage, UpdateProblem> {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // ditto, not unzip: it keeps the bundle's symlinks, extended attributes and
    // — the part that matters — the code signature intact. `unzip` mangles all
    // three, and a mangled signature fails verification, which would look like a
    // tampered download rather than the wrong tool.
    let p = runProc("/usr/bin/ditto", ["-x", "-k", zip, dir])
    guard p.terminationStatus == 0 else { return .failure(UpdateProblem(reason: "couldn't expand the download")) }
    guard let entries = try? fm.contentsOfDirectory(atPath: dir),
          let app = entries.first(where: { $0.hasSuffix(".app") }) else {
        return .failure(UpdateProblem(reason: "no app inside the download"))
    }
    let appPath = "\(dir)/\(app)"
    guard let plist = NSDictionary(contentsOfFile: "\(appPath)/Contents/Info.plist"),
          let v = plist["CFBundleShortVersionString"] as? String,
          let id = plist["CFBundleIdentifier"] as? String else {
        return .failure(UpdateProblem(reason: "the app inside the download has no version"))
    }
    return .success(UpdatePackage(appPath: appPath, version: v, bundleID: id))
}

/// One web request, tried again while updateRetryDelay says so. Waits for the
/// answer, so call it OFF the main thread. `status` is nil when there was no
/// answer at all; `data` is set only for a 2xx answer.
///
/// `delays` is a parameter for the self-test, which cannot sit through 17 s.
func fetchWithRetry(_ url: URL, accept: String? = nil, timeout: TimeInterval,
                    delays: [Double] = updateRetryDelays,
                    onRetry: ((_ nextAttempt: Int, _ status: Int?) -> Void)? = nil)
    -> (data: Data?, status: Int?, attempts: Int) {
    var attempt = 0
    while true {
        attempt += 1
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        // A cached 503 must not be served back to the retry.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let a = accept { req.setValue(a, forHTTPHeaderField: "Accept") }
        var data: Data?, status: Int?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, err in
            status = err == nil ? (resp as? HTTPURLResponse)?.statusCode : nil
            data = d
            done.signal()
        }.resume()
        done.wait()
        if updateFetchOutcome(status: status) == .ok { return (data, status, attempt) }
        guard let wait = updateRetryDelay(afterAttempt: attempt, status: status, delays: delays) else {
            return (nil, status, attempt)
        }
        wlog("update: try \(attempt) got \(status.map(String.init) ?? "no answer"), again in \(wait)s")
        onRetry?(attempt + 1, status)
        Thread.sleep(forTimeInterval: wait)
    }
}

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
    // Ask GitHub for the newest release. Read-only, anonymous, one request per
    // launch (a few more if GitHub does not answer the first time).
    //
    // A check that fails is SHOWN, with "Check again" and the releases page. It
    // used to end silently, which looked exactly like "up to date" with the
    // label missing, and the only way to check again was to restart the app.
    @objc func checkForUpdates() {
        guard !updateChecking,
              let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest") else { return }
        updateChecking = true
        if updateCheckFailed, updateLabel != nil {
            updateLabel.stringValue = "· Checking…"
            updateLabel.textColor = .tertiaryLabelColor
            updateBtn.isEnabled = false
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = fetchWithRetry(url, accept: "application/vnd.github+json", timeout: 8)
            let j = r.data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.updateChecking = false
                guard let j = j, let tag = j["tag_name"] as? String else {
                    self.showUpdateCheckFailed(status: r.status, attempts: r.attempts)
                    return
                }
                let notes = (j["body"] as? String) ?? ""
                // The zip, not the dmg: ditto expands it with the signature intact,
                // while a dmg would have to be mounted, copied out and detached —
                // three more things to leave behind on a failure.
                let assets = (j["assets"] as? [[String: Any]]) ?? []
                let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String
                self.latestZipURL = zip
                self.showUpdateStatus(tag: tag, notes: notes)
            }
        }
    }
    /// The check did not get an answer. The two buttons of the update row take
    /// on other jobs until a check works: "Check again" and "Releases page".
    func showUpdateCheckFailed(status: Int?, attempts: Int) {
        wlog("update: check failed after \(attempts) tries, \(status.map { "error \($0)" } ?? "no answer")")
        updateCheckFailed = true
        guard updateLabel != nil else { return }
        updateLabel.stringValue = "· Couldn't check for updates"
        updateLabel.toolTip = updateFailureText(status: status) + "."
        updateLabel.textColor = .secondaryLabelColor
        updateBtn.title = "Check again"
        updateBtn.isEnabled = true
        updateBtn.isHidden = false
        notesBtn.title = "Releases page"
        notesBtn.isHidden = false
    }
    func showUpdateStatus(tag: String, notes: String) {
        latestTag = tag; latestNotes = notes
        guard updateLabel != nil else { return }
        updateCheckFailed = false
        updateBtn.title = "Update now"
        updateBtn.isEnabled = true
        notesBtn.title = "What's new"
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
            notesBtn.isHidden = false
            // Once per launch, and never while SAI is open — installUpdate
            // checks that too, but deciding it here keeps the quiet path quiet.
            if autoUpdateEnabled(), !autoUpdateTried, !saiWindowIsOpen() {
                autoUpdateTried = true
                installUpdate(auto: true)
            }
        } else {
            updateLabel.stringValue = "· up to date"
            updateLabel.toolTip = nil
            updateLabel.textColor = .tertiaryLabelColor
            updateBtn.isHidden = true
            notesBtn.isHidden = true
        }
    }
    @objc func openReleasePage() {
        let s = latestTag.map { "https://github.com/\(repoSlug)/releases/tag/\($0)" }
            ?? "https://github.com/\(repoSlug)/releases/latest"
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

// ============================================================================
// SELF-UPDATE — download the release, swap the bundle, come back running.
//
// Deliberately absent for a long time, for a good reason: replacing our own
// binary drops the Input Monitoring grant, because an ad-hoc signature IS the
// hash of that exact build, so every release is a different app as far as TCC
// is concerned. That cost doesn't go away by ignoring it — the manual swap has
// it too, and there it arrives unannounced. So the update installs itself and
// then SAYS what it cost, which is the honest version of the same trade.
//
// Everything except the download is testable without the network: unpacking and
// verifying are pure enough to drive from a local zip (SAIPP_SELFTEST_UPDATE_ZIP),
// and the swap can be pointed at a throwaway directory.
// ============================================================================

extension SetupController {

    /// The signature has to verify — not to prove who built it (ad-hoc proves
    /// nobody), but to prove the bundle arrived whole. A half-extracted app that
    /// replaces the working one is the worst outcome this feature can have.
    func signatureIsIntact(_ appPath: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--strict", appPath]
        // codesign explains a bad signature on stderr, and that explanation is
        // ours to report, not to print over whatever the caller was saying.
        p.standardError = Pipe(); p.standardOutput = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Replace `dest` with `newApp` once this process has exited, then relaunch.
    ///
    /// Done by a detached script rather than in-process: we are the thing being
    /// replaced. It waits for our PID to go, swaps with ditto, strips the
    /// quarantine flag it inherited from the download (this is the same app the
    /// user already opened once — making them right-click → Open again for an
    /// update they asked for is a punishment for updating), and opens it.
    func swapAndRelaunch(newApp: String, dest: String, scriptDir: String, relaunch: Bool = true) -> Bool {
        // Order matters more than it looks. This used to delete the installed
        // app and THEN copy the new one in, so a ditto that failed for any
        // reason — a full disk, a permission, a temp directory swept from under
        // us — left the machine with no app at all and the updater already
        // gone. The copy now happens first, to a sibling path so the final move
        // is a rename on the same filesystem, and the old bundle is moved aside
        // rather than destroyed until the new one is in place.
        let staged = (dest + ".update-staged").shellQuoted
        let backup = (dest + ".update-previous").shellQuoted
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf \(staged) \(backup)
        # Nothing is destroyed until this has succeeded.
        /usr/bin/ditto \(newApp.shellQuoted) \(staged) || exit 1
        /usr/bin/xattr -dr com.apple.quarantine \(staged) 2>/dev/null
        # Move the old one aside rather than delete it, so it can come back.
        if [ -e \(dest.shellQuoted) ] && ! mv \(dest.shellQuoted) \(backup); then
            rm -rf \(staged)
            exit 1
        fi
        if ! mv \(staged) \(dest.shellQuoted); then
            # Put the working app back exactly where it was.
            [ -e \(backup) ] && mv \(backup) \(dest.shellQuoted)
            exit 1
        fi
        rm -rf \(backup)
        \(relaunch ? "/usr/bin/open \(dest.shellQuoted)" : "")
        """
        let path = "\(scriptDir)/swap.sh"
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return false }
        _ = runProc("/bin/chmod", ["+x", path])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path]
        do { try p.run() } catch { return false }
        return true
    }
}

extension String {
    /// Quote a path for the swap script. Paths with spaces are the normal case
    /// here ("SAI Pen Pressure.app"), so this is not a nicety.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension SetupController {

    /// The whole update: download, check, swap, come back.
    @objc func updateNowTapped() {
        // The same button is "Check again" while the last check has no answer.
        if updateCheckFailed { wlog("update: Check again pressed"); checkForUpdates(); return }
        wlog("update: Update now pressed")
        subtitle.stringValue = "Checking the update…"
        installUpdate(auto: false)
    }

    func installUpdate(auto: Bool) {
        guard let tag = latestTag, isNewer(tag, than: currentVersion()) else {
            wlog("update: refused — nothing newer than \(currentVersion())")
            if !auto {
                subtitle.stringValue = "You're on the newest version."
                appAlert("You're on the newest version (\(currentVersion()).")
            }
            return
        }
        guard let zip = latestZipURL, let url = URL(string: zip) else {
            wlog("update: no installable asset in \(tag), opening the release page")
            if !auto { openReleasePage() }      // no asset we can install: hand over the page
            return
        }
        // Quitting is part of updating, and quitting takes the pressure stream
        // with it. Never do that underneath someone who is drawing.
        //
        // saiRunningInWine(), not saiWindowIsOpen(): the latter counts any window
        // whose owner name contains "sai", which includes OTHER COPIES OF THIS
        // APP. With a second copy open, the button silently refused to do
        // anything, having decided SAI was in use.
        if saiRunningInWine() {
            wlog("update: refused — SAI is on screen")
            if !auto {
                subtitle.stringValue = "Close SAI, then press Update now again."
                appAlert("Close SAI first, then press Update now again.")
            }
            return
        }
        let dest = Bundle.main.bundlePath
        guard FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent) else {
            wlog("update: refused — cannot write next to \(dest)")
            if !auto {
                subtitle.stringValue = "Can't update from this folder."
                appAlert("Can't replace the app where it is:\n\n\(dest)\n\nMove it to /Applications and try again.")
            }
            return
        }
        wlog("update: downloading \(tag)")
        updateBtn.isEnabled = false
        subtitle.stringValue = "Downloading \(tag)…"
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let work = NSTemporaryDirectory() + "saipp-update-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let zipPath = "\(work)/update.zip"
            guard isOurReleaseURL(zip, slug: self.repoSlug) else {
                DispatchQueue.main.async { self.updateFailed("that download isn't coming from this project's releases", auto: auto) }
                return
            }
            // GitHub now and then answers a download with 503 for a few
            // seconds. One such answer used to fail the whole update.
            let got = fetchWithRetry(url, timeout: 30, onRetry: { n, _ in
                DispatchQueue.main.async { self.subtitle.stringValue = "Downloading \(tag)… (try \(n))" }
            })
            guard let data = got.data else {
                DispatchQueue.main.async { self.updateFailed(updateFailureText(status: got.status), auto: auto, canRetry: true) }
                return
            }
            guard (try? data.write(to: URL(fileURLWithPath: zipPath))) != nil else {
                DispatchQueue.main.async { self.updateFailed("couldn't save the download", auto: auto) }
                return
            }
            let unpacked = unpackUpdate(zip: zipPath, into: "\(work)/x")
            switch unpacked {
            case .failure(let problem):
                DispatchQueue.main.async { self.updateFailed(problem.reason, auto: auto) }
            case .success(let pkg):
                // An identifier that differs is worth knowing about — it means a
                // release changed identity, which costs everyone their Input
                // Monitoring grant — but it is not a reason to refuse an update
                // that came from our own releases.
                if pkg.bundleID != (Bundle.main.bundleIdentifier ?? "") {
                    wlog("update: the new build has a different bundle identifier")
                }
                if let why = verifyUpdate(pkg, currentVersion: self.currentVersion(),
                                          isNewer: { self.isNewer($0, than: $1) }) {
                    DispatchQueue.main.async { self.updateFailed(why, auto: auto) }
                    return
                }
                guard self.signatureIsIntact(pkg.appPath) else {
                    DispatchQueue.main.async { self.updateFailed("the download arrived damaged", auto: auto) }
                    return
                }
                DispatchQueue.main.async {
                    // Written BEFORE we go: the next launch is a different
                    // binary and has no other way to know it is the result of an
                    // update rather than an ordinary start.
                    // The marker carries WHO is updating, not just from what.
                    // Application Support is shared by every copy of this app on
                    // the machine, so a marker left by one of them was picked up
                    // by whichever started next — a second copy announced an
                    // update it had never performed, permission warning and all.
                    try? "\(self.currentVersion())\n\(dest)".write(toFile: appSupport() + "/just-updated.txt",
                                                                   atomically: true, encoding: .utf8)
                    wlog("update: swapping \(self.currentVersion()) -> \(pkg.version)")
                    guard self.swapAndRelaunch(newApp: pkg.appPath, dest: dest, scriptDir: work) else {
                        self.updateFailed("couldn't start the swap", auto: auto); return
                    }
                    self.subtitle.stringValue = "Updating to \(pkg.version)…"
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// `canRetry`: the download did not arrive, so "Try again" is worth offering.
    func updateFailed(_ why: String, auto: Bool, canRetry: Bool = false) {
        wlog("update: failed — \(why)")
        updateBtn.isEnabled = true
        subtitle.stringValue = "Update failed: \(why)"
        guard !auto else { return }
        NSApp.activate(ignoringOtherApps: true)
        let buttons = canRetry ? "{\"Close\", \"Open releases page\", \"Try again\"}" : "{\"OK\", \"Open releases page\"}"
        let dflt = canRetry ? "Try again" : "Open releases page"
        let c = osa("button returned of (display dialog \"Update failed: \(why).\n\nYou can always download it by hand from the releases page. Nothing of yours is involved either way.\" buttons \(buttons) default button \"\(dflt)\" with icon caution)")
        if c == "Open releases page" { openReleasePage() }
        if c == "Try again" { installUpdate(auto: false) }
    }

    /// Called once at launch. Says what an update cost, at the moment it costs
    /// it — the permission is dropped by macOS, silently, and being told a week
    /// later by a stranger's issue is how this project learned that lesson.
    func announceUpdateIfJustUpdated() {
        let marker = appSupport() + "/just-updated.txt"
        let text = try? String(contentsOfFile: marker, encoding: .utf8)
        let age = (try? FileManager.default.attributesOfItem(atPath: marker)[.modificationDate] as? Date)
            .flatMap { $0 }.map { Date().timeIntervalSince($0) } ?? 0
        let old: String
        switch readUpdateMarker(text, ourPath: Bundle.main.bundlePath, ageSeconds: age) {
        case .none:      return
        case .theirs:    return                                             // not ours to announce
        case .abandoned: try? FileManager.default.removeItem(atPath: marker); return
        case .ours(let from):
            old = from
            try? FileManager.default.removeItem(atPath: marker)
        }
        wlog("update: now running \(currentVersion()), came from \(old), input monitoring = \(inputMonitoringGranted())")
        guard !inputMonitoringGranted() else {
            subtitle.stringValue = "Updated to \(currentVersion()). Everything else was kept."
            return
        }
        let c = osa("button returned of (display dialog \"Updated to \(currentVersion()).\n\nmacOS has dropped the Input Monitoring permission, because every build of this app is signed differently and it sees a new app. Nothing else changed: SAI, your licence, brushes and settings are untouched.\n\nGrant it again and the pen works as before.\" buttons {\"Later\", \"Grant…\"} default button \"Grant…\" with icon note)")
        if c == "Grant…" { grantInputMonitoring() }
    }
}

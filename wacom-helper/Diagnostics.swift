// Diagnostics.swift — the Developer tab: logs, a health report, the pressure
// recorder, and the buttons that reveal the folders involved.
//
// Moved out of main.swift unchanged. This tab exists because of one lesson
// repeated throughout this project's history: every real fix came from a log or
// a measurement, and the theories that came first were wrong. It is behind dev
// mode because it is for diagnosis, not for drawing.

import AppKit
import Foundation

extension SetupController {

    func openPath(_ p: String, createIfMissing: Bool = false) {
        if !FileManager.default.fileExists(atPath: p) {
            guard createIfMissing else { alertUser("Nothing there yet:\n\n\(p)"); return }
            try? "".write(toFile: p, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
    @objc func openHelperLog() { openPath("\(appPrefix)/helper.log") }
    @objc func openWakeLog()   { openPath("/tmp/sai-wake.log") }
    @objc func openDLLLog()    { openPath("\(appPrefix)/drive_c/wtlog.txt") }
    @objc func revealPrefix() {
        NSWorkspace.shared.selectFile(prefixSAIExe, inFileViewerRootedAtPath: appPrefix)
    }
    // Three explicit folders instead of one ambiguous "Prefix" that opened a
    // Finder window with sai2.exe selected and left you guessing what you were
    // looking at.
    @objc func openSAIInWine()   { openFolder(prefixSAIDir) }     // the copy that RUNS
    /// Reveal the certificate itself, so "where did it actually go?" is one click.
    @objc func revealLicense() {
        guard let name = installedLicenseName(), let dir = licenseLocations().first else {
            alertUser("No license installed yet.\n\nUse Install… on the SAI license row — licenses come from SYSTEMAX, this app can't provide one.")
            return
        }
        NSWorkspace.shared.selectFile("\(dir)/\(name)", inFileViewerRootedAtPath: dir)
    }
    @objc func openWinePrefix()  { openFolder(appPrefix) }        // the whole bottle
    @objc func openAppSupport()  { openFolder(appSupport()) }     // config, licence stash, recordings
    func openFolder(_ p: String) {
        guard FileManager.default.fileExists(atPath: p) else { alertUser("That folder doesn't exist yet:\n\n\(p)"); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
    // ---- health check -------------------------------------------------------
    // Verifies every moving part is actually where it has to be. This is the
    // check that would have answered "I removed some files and nothing works"
    // in one click instead of a debugging session.
    func runCapture(_ exe: String, _ args: [String], env: [String: String] = [:]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        if !env.isEmpty { var e = ProcessInfo.processInfo.environment; env.forEach { e[$0] = $1 }; p.environment = e }
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
    @objc func healthCheckTapped() {
        console.string = "Running health check… (querying the Wine registry, a few seconds)"
        subtitle.stringValue = "Running health check…"
        DispatchQueue.global().async {
            let report = self.buildHealthReport()
            DispatchQueue.main.async {
                self.console.string = report
                self.console.scrollToEndOfDocument(nil)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                self.subtitle.stringValue = "Health check done — copied to clipboard."
            }
        }
    }
    func buildHealthReport() -> String {
        let fm = FileManager.default
        var lines: [String] = ["=== SAI Pen Pressure — health check ===",
                               "version \(currentVersion())", ""]
        var problems = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "", fatal: Bool = true) {
            if !ok && fatal { problems += 1 }
            let mark = ok ? "OK  " : (fatal ? "FAIL" : "warn")
            lines.append("[\(mark)] \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        // --- Wine
        let wine = wineBin()
        check("Wine runtime", wine != nil, wine ?? "not found in /Applications or $WINE")

        // --- source folder
        let src = savedSAIPath()
        check("SAI source folder recorded", src != nil, src ?? "none chosen")
        if let s = src {
            check("SAI source still exists", fm.fileExists(atPath: "\(s)/sai2.exe"),
                  fm.fileExists(atPath: "\(s)/sai2.exe") ? s : "missing sai2.exe at \(s)", fatal: false)
        }

        // --- prefix layout
        check("Wine prefix exists", fm.fileExists(atPath: appPrefix), appPrefix)
        check("drive_c exists", fm.fileExists(atPath: "\(appPrefix)/drive_c"))
        check("SAI2 folder in prefix", fm.fileExists(atPath: prefixSAIDir), prefixSAIDir)
        let exeAttrs = try? fm.attributesOfItem(atPath: prefixSAIExe)
        let exeSize = (exeAttrs?[.size] as? Int) ?? 0
        check("sai2.exe installed", saiInstalledInPrefix(),
              exeSize > 0 ? "\(exeSize / 1024 / 1024) MB" : "missing")
        check("install matches selected source", !prefixIsStale(),
              prefixIsStale() ? "prefix was built from: \(installedSrcPath() ?? "unknown")" : "")

        // --- the bridge
        let sysDLL = "\(appPrefix)/drive_c/windows/system32/wintab32.dll"
        check("wintab32.dll in system32", fm.fileExists(atPath: sysDLL), sysDLL)
        if let res = Bundle.main.resourcePath {
            let a = fm.contents(atPath: "\(res)/wintab32.dll")
            let b = fm.contents(atPath: sysDLL)
            if let a = a, let b = b {
                check("wintab32.dll matches this build", a == b,
                      a == b ? "" : "installed DLL differs from the one shipped in this app — Reinstall to fix", fatal: false)
            }
        }

        // --- registry
        if let w = wine {
            let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
            let ov = runCapture(w, ["reg", "query", "HKCU\\Software\\Wine\\DllOverrides", "/v", "wintab32"], env: env)
            check("DllOverrides wintab32 = native,builtin", ov.contains("native,builtin"),
                  ov.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "key not set" : "")
            let cmd = runCapture(w, ["reg", "query", "HKCU\\Software\\Wine\\Mac Driver", "/v", "LeftCommandIsCtrl"], env: env)
            check("Cmd→Ctrl remap (LeftCommandIsCtrl=Y)", cmd.uppercased().contains("Y"),
                  "", fatal: false)
        }

        // --- licence + runtime files
        check("license (.slc) in prefix", installedLicenseName() != nil,
              installedLicenseName() ?? "none — SAI can draw but not save", fatal: false)
        check("stashed license backup", !slcFiles(in: licenseStashDir()).isEmpty,
              slcFiles(in: licenseStashDir()).joined(separator: ", "), fatal: false)
        check("pressure file", fm.fileExists(atPath: "\(appPrefix)/drive_c/wt_pressure.txt"),
              "", fatal: false)

        // --- permission
        check("Input Monitoring granted", inputMonitoringGranted(),
              inputMonitoringGranted() ? "" : "System Settings → Privacy & Security → Input Monitoring")

        lines.append("")
        lines.append(problems == 0
            ? "RESULT: everything checks out."
            : "RESULT: \(problems) problem\(problems == 1 ? "" : "s") found. 'Install from scratch' fixes most of them.")
        return lines.joined(separator: "\n")
    }
    func wakeLogLineCount() -> Int {
        guard let s = try? String(contentsOfFile: "/tmp/sai-wake.log", encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").count
    }
    @objc func toggleRecord() {
        if recording != nil { stopRecording(); return }
        _ = startPressureEngineOnce()      // so pen counters actually move
        recMaxPressure = 0; recPressSamples = 0
        recording = RecSnapshot(t: Date(), seq: seq, tabletPtr: g_evTabletPtr,
                                tabletMouse: g_evTabletMouse, prox: g_evProx,
                                plainMouse: g_evPlainMouse, wakeLines: wakeLogLineCount())
        recBtn.title = "■ Stop recording"
        console.string = "● Recording… reproduce the problem now, then press Stop."
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.recording != nil else { return }
            let p = max(0, lastKeyP)
            if p > 0 { self.recPressSamples += 1 }
            if p > self.recMaxPressure { self.recMaxPressure = p }
        }
        RunLoop.main.add(t, forMode: .common)
        recTimer = t
        wlog("=== RECORDING STARTED ===")
    }
    func stopRecording() {
        guard let r = recording else { return }
        wlog("=== RECORDING STOPPED ===")
        recTimer?.invalidate(); recTimer = nil
        recording = nil
        recBtn.title = "● Record session"

        let dur = Date().timeIntervalSince(r.t)
        // only the wake-log lines written during the window
        var newLines: [String] = []
        if let s = try? String(contentsOfFile: "/tmp/sai-wake.log", encoding: .utf8) {
            newLines = s.split(separator: "\n").map(String.init).dropFirst(r.wakeLines).map { $0 }
        }
        let win = g_saiWindow.isEmpty ? "none on screen"
            : "\(Int(g_saiWindow.width))x\(Int(g_saiWindow.height)) at (\(Int(g_saiWindow.minX)),\(Int(g_saiWindow.minY)))"
        let pct = Int((Double(recMaxPressure) / Double(PressureCore.maxPressure) * 100).rounded())
        var out = """
        === SAI Pen Pressure — session recording ===
        version   \(currentVersion())      duration  \(String(format: "%.1fs", dur))
        started   \(r.t)

        --- pen ---
        samples streamed to SAI   \(seq - r.seq)
        tablet pointer events     \(g_evTabletPtr - r.tabletPtr)
        tablet-mouse events       \(g_evTabletMouse - r.tabletMouse)
        proximity changes         \(g_evProx - r.prox)
        PLAIN mouse events        \(g_evPlainMouse - r.plainMouse)
        max pressure              \(recMaxPressure)/\(PressureCore.maxPressure) (\(pct)%)
        frames with pen down      \(recPressSamples)
        pen seen this session     \(g_penEverSeen)

        --- SAI ---
        window                    \(win)
        menu strip active         \(!g_saiStrip.isEmpty)
        auto-wake enabled         \(autoWake)

        --- setup ---
        prefix                    \(appPrefix)
        sai2.exe installed        \(saiInstalledInPrefix())
        prefix stale              \(prefixIsStale())
        license                   \(installedLicenseName() ?? "none")
        Input Monitoring          \(inputMonitoringGranted())

        --- wake log during recording (\(newLines.count) lines) ---
        """
        out += "\n" + (newLines.isEmpty ? "(nothing — no wake/auto-wake fired)" : newLines.joined(separator: "\n"))

        // interpretation, so the numbers mean something without reading the code
        var notes: [String] = []
        if seq - r.seq == 0 { notes.append("• No pen samples reached SAI. Either the pen wasn't used, or Input Monitoring is off.") }
        if g_evPlainMouse - r.plainMouse > 0 && g_evTabletMouse - r.tabletMouse == 0 && g_penEverSeen {
            notes.append("• Pen arrived as a PLAIN mouse — the Wacom driver demoted it. That's the app-switch freeze signature (issue #2).")
        }
        if recMaxPressure == 0 && seq - r.seq > 0 { notes.append("• Samples flowed but pressure never exceeded 0 — hover only, no contact.") }
        if !newLines.isEmpty { notes.append("• Wake activity fired during this window (see above).") }
        if !notes.isEmpty { out += "\n\n--- notes ---\n" + notes.joined(separator: "\n") }

        console.string = out
        console.scrollToEndOfDocument(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)

        let dir = appSupport() + "/recordings"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let path = "\(dir)/session-\(f.string(from: r.t).replacingOccurrences(of: ":", with: "-")).log"
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        subtitle.stringValue = "Recording saved + copied to clipboard."
    }
    @objc func copyDiagnostics() {
        let fm = FileManager.default
        var os = ProcessInfo.processInfo.operatingSystemVersionString
        os = os.replacingOccurrences(of: "Version ", with: "")
        let lines = [
            "SAI Pen Pressure \(currentVersion())",
            "macOS: \(os)",
            "Wine: \(wineBin() ?? "NOT FOUND")",
            "Prefix: \(appPrefix)  (exists: \(fm.fileExists(atPath: appPrefix)))",
            "SAI source: \(savedSAIPath() ?? "none")",
            "SAI installed from: \(installedSrcPath() ?? "unknown")",
            "sai2.exe in prefix: \(saiInstalledInPrefix())",
            "prefix stale: \(prefixIsStale())",
            "license: \(installedLicenseName() ?? "none")",
            "wintab32.dll: \(fm.fileExists(atPath: "\(appPrefix)/drive_c/windows/system32/wintab32.dll"))",
            "Input Monitoring: \(inputMonitoringGranted())",
            "auto-wake: \(autoWake)",
        ]
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        alertUser("Diagnostics copied to the clipboard:\n\n\(text)")
    }
}

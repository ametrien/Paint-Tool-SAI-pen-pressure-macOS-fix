// SelfTests.swift — the command-line hooks tests/run-tests.sh drives the real
// binary through.
//
// Moved out of main.swift, where they were top-level code; the only change is
// that they now sit inside one function, which main.swift calls from the place
// they used to be. Each hook is inert without its environment variable, and
// each one EXITS when it has run: they run instead of the app, never beside it.
// That is why this file, like the top of main.swift, is left out of the test
// that forbids a bare exit() in the running app (tests/run-tests.sh, "Every
// exit from the running app ends the recording first").

import AppKit
import Foundation

/// Run a self-test hook if the environment asks for one. Returns only when it
/// asks for none.
///
/// Call it where main.swift does, after the prefix paths exist: an earlier
/// version of the first hook read prefixSAIDir before it was set and silently
/// reported "SAI isn't installed".
func runSelfTestIfAsked() {
    /// Self-test entry point for the SAI update, used by tests/run-tests.sh.
    ///
    /// This is the only code in the app that deletes a user's SAI folder and puts
    /// it back, so it is worth a real test rather than a careful reading. The test
    /// points SAI_PREFIX at a throwaway prefix, runs the update, and checks what
    /// survived. Guarded by an environment variable, so it is inert in normal use.
    ///
    /// Placement matters: top-level `let`s in main.swift initialise in file order,
    /// and an earlier version of this hook read prefixSAIDir before it existed and
    /// silently reported "SAI isn't installed".
    if let src = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_UPDATE"] {
        let result = updateSAIFromFolder(src)
        print(result ?? "OK")
        exit(result == nil ? 0 : 1)
    }

    /// Self-test hook for the library: file whatever the encoder left in staging,
    /// print where each session went, and exit. Filing MOVES a session's only copy
    /// into a drawing's folder, so it is tested against a real throwaway folder
    /// rather than reasoned about — the same treatment, for the same reason, as the
    /// SAI-update hook above. Inert without the environment variable.
    /// Self-test hook: build the Timelapses tab and print what it actually laid out.
    ///
    /// This exists because the tab shipped BLANK. Every row was built, added and
    /// unhidden — and drawn at zero size, because a stack view used as a scroll
    /// view's documentView is laid out by constraints and it had been left on
    /// autoresizing translation. Nothing about the code reads as wrong; only the
    /// measured frames say so, which is exactly what this prints.
    /// Self-test hook for the bridge check (#29): print what the app would say
    /// about the prefix in SAI_PREFIX, and exit.
    ///
    /// "Is the bridge installed?" became a question with consequences — a wrong yes
    /// sends someone off re-granting permissions and reinstalling their tablet
    /// driver while the actual fault sits in one registry line — so the answer is
    /// asserted against a real throwaway prefix rather than reasoned about. Inert
    /// without the environment variable.
    /// Self-test hook for the in-app update: unpack a local zip, check whether we
    /// would accept it, and (optionally) perform the swap into a throwaway folder.
    ///
    /// The download is the only part not covered here, and it is the part that
    /// cannot quietly do the wrong thing — it either arrives or it doesn't. What can
    /// go quietly wrong is accepting a bundle we shouldn't, or swapping a broken one
    /// over a working app, so those run against real files on a real disk.
    if let zip = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_UPDATE_ZIP"] {
        let c = SetupController()
        let work = NSTemporaryDirectory() + "saipp-selftest-\(UUID().uuidString)"
        switch unpackUpdate(zip: zip, into: "\(work)/x") {
        case .failure(let problem):
            print("unpack=failed reason=\(problem.reason)")
            exit(1)
        case .success(let pkg):
            print("unpack=ok version=\(pkg.version) id=\(pkg.bundleID)")
            let cur = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_UPDATE_FROM"] ?? "0.0.1"
            let why = verifyUpdate(pkg, currentVersion: cur, isNewer: { c.isNewer($0, than: $1) })
            print("verify=\(why ?? "ok")")
            print("signature=\(c.signatureIsIntact(pkg.appPath) ? "ok" : "damaged")")
            // The guard that actually matters now: where the file came from.
            if let u = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_UPDATE_URL"] {
                print("source=\(isOurReleaseURL(u, slug: c.repoSlug) ? "ours" : "refused")")
            }
            if let dest = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_UPDATE_DEST"], why == nil {
                // SAIPP_SELFTEST_UPDATE_BREAK makes the copy step fail, by handing
                // the swap a source that isn't there. The installed app must
                // survive that: the swap deletes nothing until the copy has
                // succeeded, and an interrupted update that leaves someone with no
                // app at all is the worst outcome this feature has.
                let source = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_UPDATE_BREAK"] != nil
                    ? pkg.appPath + ".does-not-exist"
                    : pkg.appPath
                let started = c.swapAndRelaunch(newApp: source, dest: dest, scriptDir: work, relaunch: false)
                print("swapStarted=\(started)")
            }
            exit(0)
        }
    }

    // The update's web requests against a real (local) server: does a 503 get
    // another try, and does a 404 not. Prints what happened; tests/run-tests.sh
    // serves the answers and reads this.
    if let u = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_FETCH_URL"], let url = URL(string: u) {
        var retries = 0
        let r = fetchWithRetry(url, timeout: 5, delays: [0.05, 0.05, 0.05], onRetry: { _, _ in retries += 1 })
        let body = r.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        print("status=\(r.status.map(String.init) ?? "none") attempts=\(r.attempts) retries=\(retries) body=\(body)")
        print("says=\(updateFailureText(status: r.status))")
        exit(0)
    }

    // The report redaction is only a safeguard if it is on for someone who never
    // went looking for it, so the DEFAULT is the thing worth asserting.
    if ProcessInfo.processInfo.environment["SAIPP_SELFTEST_REPORT"] != nil {
        print("redactDefault=\(reportRedactEnabled())")
        let sample = "Prefix: \(NSHomeDirectory())/SAI2-pressure"
        let shown = reportRedactEnabled()
            ? ReportCore.redactHome(sample, home: NSHomeDirectory()) : sample
        print("sample=\(shown)")
        setReportRedact(false)
        print("afterOff=\(reportRedactEnabled())")
        setReportRedact(true)
        print("afterOn=\(reportRedactEnabled())")
        exit(0)
    }

    if let mode = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_BRIDGE"] {
        // "repair" exercises the healing path itself against a real prefix — the
        // half that unit tests cannot reach, because putting the key back needs
        // wine. Run it with SAI CLOSED: wineserver rewrites user.reg when it exits
        // and would undo the repair, which is the same reason the app repairs
        // before launching rather than after.
        // "install" runs the whole bridge install and prints whether it worked.
        // Point SAIPP_SELFTEST_WINE at something that isn't wine and it must answer
        // false: before #34 there was no answer at all, which is how a prefix could
        // come out of setup with no override and nobody any the wiser.
        if mode == "install" {
            let w = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_WINE"] ?? wineBin() ?? ""
            print("installBridge=\(installBridge(w))")
            print("override=\(BridgeCheck.overrideValue(inUserReg: readUserReg() ?? "") ?? "-")")
            exit(0)
        }
        if mode == "repair" {
            print("before=\(BridgeCheck.overrideValue(inUserReg: readUserReg() ?? "") ?? "-")")
            let repaired = ensureBridgeOverride(wineBin())
            print("repaired=\(repaired)")
            // Two answers on purpose. user.reg still names the OLD value for
            // seconds after a repair that worked — wineserver flushes it on exit —
            // so "after" asks wine, and "afterFile" is printed beside it to keep
            // that lag visible rather than surprising. Believing the file here is
            // exactly what made the app report a successful repair as a failure.
            print("after=\(wineBin().flatMap { bridgeOverrideViaWine($0) } ?? "-")")
            print("afterFile=\(BridgeCheck.overrideValue(inUserReg: readUserReg() ?? "") ?? "-")")
            exit(bridgeOverrideInstalled() ? 0 : 1)
        }
        // "probe" runs the far-side test headlessly: the same wtprobe.exe the Pen
        // tab's button runs, so the wiring can be checked without a hand on the
        // tablet. Press the pen while it runs to get past noPackets.
        if mode == "probe" {
            guard let w = wineBin() else { print("probe=nowine"); exit(1) }
            let pr = runBridgeProbe(w, seconds: 5)
            print("parsed=\(pr != nil)")
            print("ours=\(pr?.ours ?? false)")
            print("ctxOpen=\(pr?.contextOpen ?? false)")
            print("msgs=\(pr?.msgs ?? 0) fetched=\(pr?.fetched ?? 0) pmax=\(pr?.pmaxSeen ?? 0)")
            let v = BridgeCheck.probeVerdict(pr)
            print("verdict=\(v)")
            print("detail=\(BridgeCheck.explainProbe(v, pr))")
            exit(v == .working || v == .noPackets ? 0 : 1)
        }
        // "stream" exercises BridgeProbeStream — the class behind the second bar in
        // the Pen tab — outside the GUI, where a stall is visible instead of just
        // being a bar that never moves.
        if mode == "stream" {
            guard let w = wineBin() else { print("stream=nowine"); exit(1) }
            let st = BridgeProbeStream()
            var ticks = 0
            st.onVerdict = { v, _ in print("verdict=\(v)") }
            st.onTick = { t in
                ticks += 1
                if ticks <= 3 || ticks % 20 == 0 { print("tick #\(ticks) p=\(t.pressure) fetched=\(t.fetched)") }
            }
            st.start(w, seconds: 20)
            RunLoop.main.run(until: Date().addingTimeInterval(8))
            st.stop()
            print("ticks=\(ticks)")
            exit(ticks > 0 ? 0 : 1)
        }
        let (st, age) = bridgeStatus()
        // Printed so the tests can skip the cases that assume SAI is closed rather
        // than fail on a machine where it happens to be open.
        print("saiRunning=\(saiRunningInWine())")
        print("installedOK=\(bridgeInstalledOK())")
        print("override=\(BridgeCheck.overrideValue(inUserReg: readUserReg() ?? "") ?? "-")")
        print("verdict=\(BridgeCheck.verdict(st, ageSeconds: age))")
        print("detail=\(bridgeDetailLine())")
        exit(0)
    }

    /// Self-test hook for the uninstall: the most destructive path in the app.
    ///
    /// removeWine is ALWAYS false here. The real thing can move Wine Staging to the
    /// Trash, and a test that did that would reach outside its throwaway directories
    /// and take a real application off the machine running it.
    if let mode = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_UNINSTALL"] {
        let c = SetupController()
        c.performUninstall(keepLicense: mode == "keep", removeWine: false)
        let fm = FileManager.default
        print("prefix exists=\(fm.fileExists(atPath: appPrefix))")
        for f in ["config.txt", "devmode.txt", "installed-src.txt"] {
            print("\(f) exists=\(fm.fileExists(atPath: appSupport() + "/" + f))")
        }
        print("stash \(slcFiles(in: licenseStashDir()).joined(separator: ",")) ")
        let videos = timelapseOutputFolder()
        let names = ((try? fm.contentsOfDirectory(atPath: videos)) ?? []).sorted()
        print("videos \(names.joined(separator: ","))")
        print("index exists=\(fm.fileExists(atPath: timelapseLibraryPath()))")
        exit(0)
    }

    /// Self-test hook for the licence: the one file in this app nobody can recreate.
    ///
    /// It drives the exact sequence performSetup(.rebuild) performs around the point
    /// where it deletes the whole prefix — adopt whatever is in the prefix, delete
    /// the prefix, put it back — because that deletion is where a certificate would
    /// be lost, and every call on the path is a silent `try?`.
    ///
    /// Wine is not involved and cannot be: the wineboot in performSetup takes a
    /// minute and needs a real Wine. What is being tested is the rescue, not the
    /// prefix build.
    if let step = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_LICENSE"] {
        switch step {
        case "rebuild":
            // Exactly performSetup's order, and nothing else.
            adoptLicenseFromSourceFolder(prefixSAIDir)
            try? FileManager.default.removeItem(atPath: appPrefix)
            restoreStashedLicenses()
        case "adopt-source":
            // Picking a SAI folder that already holds a certificate.
            if let n = adoptLicenseFromSourceFolder(CommandLine.arguments.dropFirst().first ?? "") {
                print("adopted \(n)")
            }
        case "install":
            let src = CommandLine.arguments.dropFirst().first ?? ""
            print("installed=\(installLicenseFile(src))")
        case "restore":
            restoreStashedLicenses()
        default:
            break
        }
        for d in licenseDirs {
            for f in slcFiles(in: d) { print("prefix \((d as NSString).lastPathComponent)/\(f)") }
        }
        for f in slcFiles(in: licenseStashDir()) { print("stash \(f)") }
        exit(0)
    }

    /// Self-test hook: where would this session record to? Guards the upgrade path,
    /// where a marker left by an older version pointed outside staging.
    if ProcessInfo.processInfo.environment["SAIPP_SELFTEST_SESSIONBASE"] != nil {
        print(timelapseSessionBase())
        exit(0)
    }

    if let dir = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_TABLAYOUT"] {
        _ = NSApplication.shared
        let c = SetupController()
        let tab = c.buildLibraryTab()
        // A window, because view layout outside one is undefined — and the bug
        // being guarded against is precisely a view that never gets a size.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                         styleMask: [.titled], backing: .buffered, defer: false)
        tab.translatesAutoresizingMaskIntoConstraints = true
        tab.autoresizingMask = [.width, .height]
        tab.frame = w.contentView!.bounds
        w.contentView?.addSubview(tab)
        w.layoutIfNeeded()
        func dump(_ v: NSView, _ depth: Int) {
            // A pull-down's items are menu items, not subviews, so they are listed
            // explicitly or the More menu would be invisible to the test.
            let name = (v as? NSTextField)?.stringValue
                ?? (v as? NSPopUpButton).map { "popup[" + $0.itemTitles.joined(separator: "|") + "]" }
                ?? (v as? NSButton)?.title
                ?? String(describing: type(of: v))
            print(String(format: "%@%@ %.0fx%.0f", String(repeating: "  ", count: depth),
                         name, v.frame.width, v.frame.height))
            for s in v.subviews { dump(s, depth + 1) }
        }
        dump(tab, 0)
        print("rows \(c.libStack.arrangedSubviews.count) "
              + "stack \(Int(c.libStack.frame.width))x\(Int(c.libStack.frame.height))")
        // Counted from the model, never by grepping the dump above: an NSButton has
        // an inner view carrying the same title on some macOS versions, so counting
        // rows by their button text read 2 locally and 4 on CI.
        func hoverRows(_ v: NSView) -> Int {
            (v is HoverVideoView ? 1 : 0) + v.subviews.reduce(0) { $0 + hoverRows($1) }
        }
        let drawn = c.libStore?.lib.drawings.count ?? 0
        print("rows drawings=\(drawn) loose=\(hoverRows(tab) - drawn)")

        // Changing the videos folder must reload the list in place — the whole point
        // being that you do not have to quit the app to see the other folder.
        if let switchTo = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_FOLDERSWITCH"] {
            c.setTimelapseFolder(switchTo)
            w.layoutIfNeeded()
            print("--- after switching to \(switchTo)")
            dump(tab, 0)
            print("rows \(c.libStack.arrangedSubviews.count) "
                  + "stack \(Int(c.libStack.frame.width))x\(Int(c.libStack.frame.height))")
        }

        // Hovering plays the video. The tracking area is AppKit's business; that a
        // row is wired to a player, and lets go of it again, is ours.
        if ProcessInfo.processInfo.environment["SAIPP_SELFTEST_HOVER"] != nil {
            var rows: [HoverVideoView] = []
            func collect(_ v: NSView) {
                if let hv = v as? HoverVideoView { rows.append(hv) }
                for sub in v.subviews { collect(sub) }
            }
            collect(tab)
            print("hoverable \(rows.count)")
            if let first = rows.first {
                first.beginPreview()
                w.layoutIfNeeded()
                print("hover begin previewing=\(first.isPreviewing)")
                // The preview must stay inside the thumbnail. An unclipped player
                // layer draws the video at its own size over the rows below — it
                // covered half the tab before this was checked.
                let inside = first.subviews.allSatisfy {
                    $0.frame.width <= first.bounds.width + 0.5
                        && $0.frame.height <= first.bounds.height + 0.5
                }
                let pf = first.previewFrame
                let layerFits = pf.width > 0 && pf.width <= first.bounds.width + 0.5
                    && pf.height <= first.bounds.height + 0.5
                print("hover box \(Int(first.bounds.width))x\(Int(first.bounds.height))"
                      + " video \(Int(pf.width))x\(Int(pf.height))"
                      + " inside=\(inside) layerFits=\(layerFits) clips=\(first.layer?.masksToBounds ?? false)")
                first.endPreview()
                print("hover end previewing=\(first.isPreviewing)")
            }
            // Moving across rows must leave ONE playing, not one per row crossed.
            for r in rows { r.beginPreview() }
            print("hover concurrent \(rows.filter(\.isPreviewing).count) of \(rows.count)")
            for r in rows { r.endPreview() }
        }
        _ = dir
        exit(0)
    }

    if let dir = ProcessInfo.processInfo.environment["SAIPP_SELFTEST_LIBRARY"] {
        let store = LibraryStore(videosDir: dir, indexPath: dir + "/.library.json")
        if store.recoveredFromBrokenIndex { print("recovered from a broken index") }
        for f in store.fileFinishedSessions() {
            let d = store.lib.drawing(id: f.drawingId)
            print("filed \(f.pieceFile) -> \(d?.folder ?? "?")"
                  + (f.askAbout.map { " ask:\(store.lib.drawing(id: $0)?.folder ?? "?")" } ?? ""))
        }
        // Answering the question is part of the same path and needs the same proof.
        if ProcessInfo.processInfo.environment["SAIPP_SELFTEST_CONFIRM"] == "same",
           let p = store.lib.pending.first {
            store.confirmSame(p)
            print("confirmed same -> \(store.lib.drawing(id: p.candidateId)?.folder ?? "?")")
        }
        for d in store.lib.drawings.sorted(by: { $0.folder < $1.folder }) {
            print("drawing \(d.folder) [\(d.title)]: \(d.ordered.map(\.file).joined(separator: ", "))")
        }
        exit(0)
    }
}

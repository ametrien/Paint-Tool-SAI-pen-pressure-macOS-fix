// AutoWake.swift — getting SAI to take input again when its window comes back
// "stuck" after an app switch (issue #2).
//
// Moved out of main.swift unchanged. The macOS half lives here: finding the
// process that owns SAI's window, re-activating it, and deciding WHEN to (an
// app switch, a dead click, the button, the hotkey). The Win32 half runs inside
// SAI, in our DLL; bumpWin32Wake() is how this side asks for it.
//
// The state these methods share (autoWake, bouncing, lastReactivate, wakeSeq)
// is declared in the class in main.swift, because an extension cannot hold
// stored properties. Three more triggers stay there too, being app-delegate
// callbacks: Dock reopen, losing focus to SAI, and the wiring at launch.

import AppKit
import Foundation

extension SetupController {

    // Find the running Wine/SAI app (the process SAI runs inside).
    func wineRunningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            let hay = "\(app.bundleIdentifier ?? "") \(app.localizedName ?? "") \(app.executableURL?.path ?? "")".lowercased()
            return hay.contains("wine") || hay.contains("sai")
        }
    }

    // Force SAI's window fully active again. Hiding then re-activating the app is
    // a full activation cycle — the strongest, permission-free equivalent of the
    // Space-swipe — so a "stuck"/greyed window becomes key and takes clicks again.
    // Find the process that owns SAI's biggest ON-SCREEN window. Wine runs as
    // several processes; only one owns the visible window we need to wake.
    // CGWindowList gives owner name/pid/bounds with NO permission (only window
    // TITLES need screen-recording, which we don't read).
    func saiWindowOwnerPID() -> pid_t {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var bestPid: pid_t = 0, bestArea = -1
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            guard owner.contains("wine") || owner.contains("sai") else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let area = Int((b["Width"] ?? 0) * (b["Height"] ?? 0))
            let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
            wlog("  win owner=\(owner) pid=\(pid) layer=\(layer) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))")
            if layer == 0 && area > bestArea { bestArea = area; bestPid = pid_t(pid) }
        }
        return bestPid
    }

    @objc func wakeSAI() {
        wlog("wakeSAI called")
        bumpWin32Wake()
        let ownerPid = saiWindowOwnerPID()
        wlog("  SAI window owner pid=\(ownerPid)")
        let app = (ownerPid != 0 ? NSRunningApplication(processIdentifier: ownerPid) : nil) ?? wineRunningApp()
        guard let app = app else { wlog("  -> NO app to target"); NSSound.beep(); return }
        // GENTLE by default: just re-activate the CORRECT window-owning process —
        // no hide. Hiding the whole app un-sticks the window but resets SAI's pen
        // state (OS arrow everywhere, can't draw until you repeat it). WT_WAKE_HIDE=1
        // forces the old heavy hide+reactivate if the gentle path isn't enough.
        if ProcessInfo.processInfo.environment["WT_WAKE_HIDE"] != nil {
            wlog("  -> hide+reactivate pid=\(app.processIdentifier)")
            app.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                app.unhide(); app.activate(options: [.activateAllWindows])
            }
        } else {
            wlog("  -> gentle activate pid=\(app.processIdentifier)")
            app.activate(options: [.activateAllWindows])
        }
        // post-transition wake, once macOS has settled (see bounceToSAI)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            wlog("  -> post-wakeSAI wake bump")
            self.bumpWin32Wake()
        }
    }

    // AUTO-WAKE (issue #2): whenever Wine/SAI comes to the front, re-activate the
    // process that actually OWNS SAI's on-screen window.
    // Why this used to fail: Wine runs as several processes. The activation
    // notification hands us the *registered* wine app (e.g. pid 40099), but the
    // visible window belongs to a different pid (e.g. 40101). Activating the
    // notified one does nothing — which is exactly why the manual button (which
    // resolves the owner via CGWindowList) works and the old auto path didn't.
    // Toggle live from the 🖊 menu; WT_NO_AUTOWAKE=1 starts it off.
    @objc func appActivated(_ note: Notification) {
        guard autoWake, !bouncing,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let hay = "\(app.bundleIdentifier ?? "") \(app.localizedName ?? "") \(app.executableURL?.path ?? "")".lowercased()
        guard hay.contains("wine") || hay.contains("sai") else { return }
        guard Date().timeIntervalSince(lastReactivate) > 0.6 else { return }   // no feedback loop
        lastReactivate = Date()
        // Let macOS finish its own activation first, then nudge the real owner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, self.autoWake else { return }
            let owner = self.saiWindowOwnerPID()
            guard owner != 0, let target = NSRunningApplication(processIdentifier: owner) else { return }
            wlog("autoWake(activate): notified pid=\(app.processIdentifier) windowOwner pid=\(owner)")
            self.bounceToSAI(target)
        }
    }

    // THE BOUNCE. Plain activate() is a no-op when macOS already thinks Wine is
    // frontmost, so the window stays stuck. The manual menu-bar button only works
    // because clicking the menu bar makes THIS app active first, making the
    // following activate() a real transition. So do that deliberately: take
    // activation for a moment, then hand it straight back to the window's real
    // owner. Our own window is minimized while you draw, so it's a brief blink.
    // Ask our DLL (which runs INSIDE SAI) to restore SAI's Win32 foreground/active
    // window. macOS-side activation alone doesn't do it: Wine can leave the Win32
    // state stale, and SAI then eats every canvas click (MA_NOACTIVATEANDEAT) so
    // the canvas is dead to pen AND mouse while the menu bar still works.
    func bumpWin32Wake() {
        wakeSeq += 1
        try? "\(wakeSeq)".write(toFile: "\(appPrefix)/drive_c/wt_wake.txt", atomically: true, encoding: .ascii)
    }

    func bounceToSAI(_ target: NSRunningApplication) {
        bouncing = true
        bumpWin32Wake()
        // Step 1: take activation AWAY from SAI. Prefer bouncing off ANOTHER Wine
        // process — Wine runs several, and switching between two of them keeps the
        // menu bar showing "Wine", so the bounce is invisible. Falling back to our
        // own app works too but blinks the menu bar.
        if let other = wineRunningApp(), other.processIdentifier != target.processIdentifier {
            wlog("  bounce via wine pid=\(other.processIdentifier)")
            other.activate(options: [])
        } else {
            wlog("  bounce via self (no second wine process)")
            NSApp.activate(ignoringOtherApps: true)
        }
        // Step 2: hand activation back to the process that owns SAI's window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            target.activate(options: [.activateAllWindows])
            wlog("  -> re-activated owner pid=\(target.processIdentifier)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.bouncing = false }
            // Bump AGAIN once the transition has settled: the bump at bounce
            // start can fire the DLL's wake MID-bounce (while the OTHER wine
            // process is still the active Cocoa app), and winemac.drv ignores
            // key-window changes for an inactive app — a wasted wake. This one
            // runs with SAI properly active, so the driver-level focus refresh
            // actually takes. See issue #2.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                wlog("  -> post-bounce wake bump")
                self.bumpWin32Wake()
            }
        }
    }

    // Auto-wake trigger #2: a click inside SAI's window. Fires ONLY when you
    // haven't drawn for a few seconds — if pressure is flowing, SAI is obviously
    // not stuck, so we never bounce mid-drawing. Covers the case the activation
    // notification can't: SAI already frontmost, stuck, and you click it again.
    func autoWakeOnClick(at loc: CGPoint) {
        guard autoWake, !bouncing else { return }
        // Don't touch clicks on the menu strip — a bounce there would dismiss the
        // menu the click just opened.
        if !g_saiStrip.isEmpty && g_saiStrip.contains(loc) { return }
        // Look at the result of the click a moment LATER. If it produced drawing,
        // SAI is obviously alive -> do nothing. If nothing happened and Wine is
        // (still) frontmost, that was a dead click -> un-stick it. This also
        // covers clicking Wine's "exec" Dock tile, which fires no activation
        // notification when Wine is already frontmost.
        let insideSAI = !g_saiWindow.isEmpty && g_saiWindow.contains(loc)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.autoWake, !self.bouncing else { return }
            let now = Date()
            guard now.timeIntervalSince(g_lastDrawAt) > 1.0,      // nothing was drawn by that click
                  now.timeIntervalSince(self.lastReactivate) > 2.0,
                  let front = NSWorkspace.shared.frontmostApplication,
                  let target = self.saiTarget() else { return }
            let hay = "\(front.bundleIdentifier ?? "") \(front.localizedName ?? "") \(front.executableURL?.path ?? "")".lowercased()
            let frontIsSAI = hay.contains("wine") || hay.contains("sai")
            if frontIsSAI {
                // On SAI, but the click drew nothing -> dead click, un-stick it.
                self.lastReactivate = now
                wlog("autoWake(click/dead): front=\(front.processIdentifier) owner=\(target.processIdentifier)")
                self.bounceToSAI(target)
            } else if insideSAI {
                // Clicked SAI's window but another app is STILL frontmost — the
                // click didn't even raise it (SAI behind another window). Coming
                // from a different app is already a real transition, so a plain
                // activate is enough; no bounce needed.
                self.lastReactivate = now
                wlog("autoWake(click/raise): front=\(front.localizedName ?? "?") -> owner=\(target.processIdentifier)")
                self.bumpWin32Wake()
                target.activate(options: [.activateAllWindows])
                // post-transition wake, once macOS has settled (see bounceToSAI)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    wlog("autoWake(click/raise): post bump")
                    self.bumpWin32Wake()
                }
            }
        }
    }

    @objc func toggleAutoWake(_ sender: NSMenuItem) {
        autoWake.toggle()
        sender.state = autoWake ? .on : .off
    }

    // Fired when the tap detects the pen was demoted to a plain mouse (the real
    // "SAI stuck" signature). Un-stick it — same bounce the button uses.
    func autoWakeStuck() {
        guard autoWake, !bouncing,
              Date().timeIntervalSince(lastReactivate) > 1.5,
              let target = saiTarget() else { return }
        lastReactivate = Date()
        wlog("autoWake(demotion): owner pid=\(target.processIdentifier)")
        bounceToSAI(target)
    }

    // The process that owns SAI's on-screen window (see saiWindowOwnerPID).
    func saiTarget() -> NSRunningApplication? {
        let owner = saiWindowOwnerPID()
        return owner != 0 ? NSRunningApplication(processIdentifier: owner) : nil
    }

    @objc func autoWakeCheckToggled() { autoWake = (autoWakeCheck.state == .on) }
}

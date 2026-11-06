// MenuBar.swift — the menu-bar item, its menu, and the Dock menu.
//
// Moved out of main.swift unchanged. The menu is deliberately three lines long:
// wake SAI, whether recording is on, and open the window. Everything else it
// once held duplicated a control in a tab, and a menu that mirrors a window is
// two places to keep in step for no gain.

import AppKit
import Foundation

extension SetupController {

    // REBUILT FROM SCRATCH (issue #14). The previous version accumulated
    // attempted fixes — autosaveName, an explicit isVisible, a symbol
    // configuration — none of which helped, and each of which was one more
    // difference from the thing that demonstrably works.
    //
    // A minimal test app on this same machine places its item correctly at
    // x≈863, while ours landed at x=1321, underneath the system clock. Five
    // theories were tested and disproven (dark emoji glyph, missing
    // autosaveName, ad-hoc signing, a full menu bar — 125pt free against 31pt
    // needed — and a stale persisted position). So rather than add a sixth,
    // this is deliberately reduced to exactly what the working control app did:
    // create, set an image, attach a menu, retain. Nothing else.
    func setUpStatusItem() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Template image, not the old "🖊": U+1F58A is a dark-grey COLOUR glyph
        // that can't adapt to the menu bar, and was near-invisible in dark mode.
        // AppKit recolours a template for both appearances.
        if let pen = NSImage(systemSymbolName: "applepencil", accessibilityDescription: "SAI Pen Pressure") {
            pen.isTemplate = true
            si.button?.image = pen
        } else {
            si.button?.title = "✏️"        // high-contrast fallback, older macOS
        }
        si.button?.toolTip = "SAI Pen Pressure"
        si.menu = makeMenu()
        statusItem = si
        watchScreenNotice()

        // Report where macOS actually put it. Kept because this bug is invisible
        // from the outside — the item reports itself as visible either way, and
        // only the frame distinguishes "shown" from "parked under the clock".
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak si] in
            guard let si = si else { wlog("statusItem: DEALLOCATED"); return }
            let f = si.button?.window?.frame
            let x = f?.origin.x ?? -1
            wlog("statusItem: visible=\(si.isVisible) frame=\(f.map { "\($0)" } ?? "nil") -> \(x > 1200 ? "BAD (parked far right, likely hidden)" : "looks placed")")
        }
    }
    /// Screens changed under a running SAI (#37): the pen still works on every
    /// screen, but a screen SAI did not know about at launch gets no pressure
    /// until SAI restarts. Nothing pops up (you may be mid-stroke); the menu-bar
    /// pen gets a warning mark and the menu's first line says what to do. Read
    /// from the DLL's status file every 2 s; cheap, and only rebuilds on change.
    func watchScreenNotice() {
        var last = BridgeCheck.ScreenNotice.none
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let (st, age) = bridgeStatus()
            let now = BridgeCheck.screenNotice(st, ageSeconds: age)
            guard now != last, let self = self else { return }
            last = now
            wlog("screen notice: \(now)")
            self.screenNotice = now
            let name = now == .none ? "applepencil" : "exclamationmark.triangle"
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "SAI Pen Pressure") {
                img.isTemplate = true
                self.statusItem?.button?.image = img
            }
            self.statusItem?.button?.toolTip = BridgeCheck.explain(now) ?? "SAI Pen Pressure"
            self.rebuildMenus()
        }
    }
    /// Rebuild both menus after something that changes their contents (dev mode).
    func rebuildMenus() { statusItem?.menu = makeMenu() }
    /// One menu definition shared by the 🖊 menu-bar item and the right-click
    /// Dock menu, so the two can't drift apart.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, state: NSControl.StateValue? = nil, indent: Int = 0) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.indentationLevel = indent
            if let s = state { it.state = s }
            menu.addItem(it)
        }
        // Kept deliberately short. Everything else lives in the Setup, Pen,
        // Recording and Developer tabs, and duplicating it here just made a menu
        // nobody could scan. What survives is what you want WITHOUT opening the
        // window: unstick SAI, see at a glance whether recording is on, and get
        // to the window itself.
        if let notice = BridgeCheck.explain(screenNotice) {
            let it = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            menu.addItem(.separator())
        }
        add("Wake SAI window (if stuck)   ⌃⌥⌘Space", #selector(wakeSAI))
        menu.addItem(.separator())
        let frames = timelapseFrameCount()
        add(timelapseOn ? "Recording timelapse" : "Timelapse recording is off",
            #selector(toggleTimelapse(_:)), state: timelapseOn ? .on : .off)
        if frames > 0 {
            add("Make video from \(frames) frame\(frames == 1 ? "" : "s")…",
                #selector(makeTimelapseVideo), indent: 1)
        }
        menu.addItem(.separator())
        add("Open Setup window", #selector(showSetupWindow))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }
    @objc func showSetupWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    // Right-click on our Dock icon. Left-click focuses SAI; the useful actions —
    // including the Developer-mode toggle — live here, which is the second place
    // (besides the menu-bar item) you can reach them.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { makeMenu() }
}

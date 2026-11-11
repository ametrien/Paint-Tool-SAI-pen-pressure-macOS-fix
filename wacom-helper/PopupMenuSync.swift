// PopupMenuSync.swift — put a dropdown's contents on screen without breaking
// a choice the user is in the middle of making.
//
// AppKit only, no app state: tests/PopupMenuTests.swift compiles this file on
// its own and drives a real NSPopUpButton offscreen.

import AppKit

/// Show `entries` in `popup` and select `selectTag`.
///
/// THE TRAP (pen feel profiles, after 0.3.10): the setup window refreshes
/// every second on a .common-mode timer, and .common timers keep firing while
/// a menu is OPEN. The first version of the profiles menu built a new NSMenu
/// on every refresh. The user opened the dropdown, a tick swapped the menu
/// out from under them, and the item they then picked belonged to the old
/// menu: the popup ignored it and stayed on Normal. Picking a preset "did
/// nothing". (0.3.10 was safe only because its refresh just re-selected.)
///
/// So the menu is rebuilt ONLY when what it shows has changed, which a timer
/// tick on its own never does. A refresh with nothing new leaves every
/// NSMenuItem the user can see in place. Do not "simplify" this back to
/// `popup.menu = NSMenu()` on every call: tests/PopupMenuTests.swift replays
/// the lost pick and fails if you do.
func syncPopupMenu(_ popup: NSPopUpButton, _ entries: [PenFeelCore.MenuEntry], selectTag: Int) {
    if popupEntries(popup) != entries {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for e in entries {
            if e.isSeparator { menu.addItem(.separator()); continue }
            let i = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
            i.tag = e.tag; i.isEnabled = e.enabled; i.toolTip = e.tip
            menu.addItem(i)
        }
        popup.menu = menu
    }
    if popup.selectedItem?.tag != selectTag { popup.selectItem(withTag: selectTag) }
}

/// What `popup` shows now, in the same terms as the entries it was built from.
func popupEntries(_ popup: NSPopUpButton) -> [PenFeelCore.MenuEntry] {
    popup.itemArray.map { i in
        i.isSeparatorItem ? .separator
            : PenFeelCore.MenuEntry(title: i.title, tag: i.tag, enabled: i.isEnabled, tip: i.toolTip)
    }
}

// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Installs a standard **Edit** menu into `NSApp.mainMenu`.
///
/// Peeknook runs as an `.accessory` app whose only window is a non-activating notch panel.
/// Such apps have no main menu by default, and in AppKit the standard text-editing shortcuts
/// (⌘A select-all, ⌘C/⌘V/⌘X, ⌘Z/⇧⌘Z) are delivered through the **main menu's key equivalents**,
/// not by the text view itself. Without an Edit menu, those keystrokes route nowhere even when a
/// text field is first responder. Installing one makes editing work in every Peeknook field.
enum StandardEditMenu {
    @MainActor
    static func installIfNeeded() {
        let app = NSApplication.shared
        let main = app.mainMenu ?? {
            let menu = NSMenu()
            // Slot 0 is treated as the app menu by AppKit; keep it present but empty (the bar
            // is never shown for an accessory app, only the key equivalents matter).
            let appItem = NSMenuItem()
            appItem.submenu = NSMenu()
            menu.addItem(appItem)
            return menu
        }()

        // Already has an Edit menu (e.g. a future host added one)? Leave it alone.
        if main.items.contains(where: { $0.submenu?.title == "Edit" }) {
            if app.mainMenu == nil { app.mainMenu = main }
            return
        }

        let editItem = NSMenuItem()
        editItem.submenu = makeEditMenu()
        main.addItem(editItem)
        app.mainMenu = main
    }

    @MainActor
    private static func makeEditMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return edit
    }
}

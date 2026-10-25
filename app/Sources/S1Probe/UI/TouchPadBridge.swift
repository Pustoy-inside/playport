// SPDX-License-Identifier: GPL-3.0-or-later
// The on-screen controller's way into the in-game menu (app/Sources/TouchPad):
// its Home button opens the menu as Home held on a pad does, and it hides
// while the menu is open. It calls these on the main thread (UIKit handlers).

import Foundation

@_cdecl("playport_touchpad_menu_open")
func playportTouchPadMenuOpen() -> Bool {
    MainActor.assumeIsolated { InGameMenu.shared.open() }
}

@_cdecl("playport_touchpad_menu_is_open")
func playportTouchPadMenuIsOpen() -> Bool {
    MainActor.assumeIsolated { InGameMenu.shared.isOpen }
}

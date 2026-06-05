// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// Height caps for notch surfaces. OpenNook sizes the panel to fit children — never use
/// raw `visibleFrame.height` as a fixed height (that blows past the notch and clips the top bar).
enum PeekPanelLayout {
    /// Settings scroll area — matches OpenNook's `SettingsView.settingsScrollMaxHeight`.
    static var settingsMaxHeight: CGFloat {
        guard let screen = notchScreen else { return 340 }
        let visibleHeight = screen.visibleFrame.height
        return min(440, max(260, visibleHeight * 0.36))
    }

    /// Home conversation — grows with content up to this cap, then scrolls.
    static var conversationMaxHeight: CGFloat {
        guard let screen = notchScreen else { return 280 }
        let visibleHeight = screen.visibleFrame.height
        return min(300, max(160, visibleHeight * 0.28))
    }

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// Height caps for notch surfaces. OpenNook sizes the panel to fit children, never use
/// raw `visibleFrame.height` as a fixed height (that blows past the notch and clips the top bar).
enum PeekPanelLayout {
    /// Settings scroll area, matches OpenNook's `SettingsView.settingsScrollMaxHeight`.
    static var settingsMaxHeight: CGFloat {
        guard let screen = notchScreen else { return 340 }
        let visibleHeight = screen.visibleFrame.height
        return min(440, max(260, visibleHeight * 0.36))
    }

    /// Home conversation, grows with content up to this cap, then scrolls.
    static var conversationMaxHeight: CGFloat {
        guard let screen = notchScreen else { return 280 }
        let visibleHeight = screen.visibleFrame.height
        return min(300, max(160, visibleHeight * 0.28))
    }

    /// Collapsed result (latest answer only). Caps a long single answer so it scrolls in place
    /// instead of growing the panel past the notch and shoving the host top bar off screen
    /// (invariant: growable surfaces self-bound against the notch). Slightly taller than the live
    /// streaming view, since the result footer/command bar are compact.
    static var resultContentMaxHeight: CGFloat {
        guard let screen = notchScreen else { return 320 }
        let visibleHeight = screen.visibleFrame.height
        return min(360, max(200, visibleHeight * 0.34))
    }

    /// Full History view (turns + usage chart in one scroll), a bit taller than the collapsed
    /// answer, still capped against the notch screen so it never pushes the host top bar off.
    static var historyMaxHeight: CGFloat {
        guard let screen = notchScreen else { return 360 }
        let visibleHeight = screen.visibleFrame.height
        return min(420, max(220, visibleHeight * 0.4))
    }

    /// Dedicated Stats drill-in, scrollable all-time analytics.
    static var statsMaxHeight: CGFloat {
        guard let screen = notchScreen else { return 400 }
        let visibleHeight = screen.visibleFrame.height
        return min(480, max(280, visibleHeight * 0.5))
    }

    /// Model library drill-in, browse and download vision models.
    static var modelLibraryMaxHeight: CGFloat {
        guard let screen = notchScreen else { return 400 }
        let visibleHeight = screen.visibleFrame.height
        return min(480, max(280, visibleHeight * 0.5))
    }

    /// First-run setup checklist, scrollable against the notch screen.
    static var setupMaxHeight: CGFloat {
        guard let screen = notchScreen else { return 360 }
        let visibleHeight = screen.visibleFrame.height
        return min(440, max(260, visibleHeight * 0.42))
    }

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

// SPDX-License-Identifier: Apache-2.0

import NookApp
import SwiftUI

/// Where Settings should scroll and expand after a recovery or deep link.
enum PeekSettingsFocus: Equatable, Sendable {
    case visionServer
}

/// Opens Settings with optional section focus (mirrors ``PeekModelLibraryNavigation``).
@MainActor
enum PeekSettingsNavigation {
    static var pendingFocus: PeekSettingsFocus?

    static func openVisionServer(appState: AppState) {
        pendingFocus = .visionServer
        appState.showSettings()
    }

    static func consumePendingFocus() -> PeekSettingsFocus? {
        defer { pendingFocus = nil }
        return pendingFocus
    }
}

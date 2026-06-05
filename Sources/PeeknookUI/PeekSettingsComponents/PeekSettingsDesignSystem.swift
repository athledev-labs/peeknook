// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

enum PeekSettingsRowMetrics {
    static let iconWidth: CGFloat = 18
    static let rowSpacing: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 4
    static let trailingColumnWidth: CGFloat = 84
}

enum PeekSettingsCommandStyle {
    case standard
    case destructive
}

enum PeekSettingsCommandTrailing {
    case chevron
    case button(String)
}

enum PeekSettingsStatusTone {
    case loading
    case ready
    case warning
    case error

    var icon: String {
        switch self {
        case .loading: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    func tint(theme: NookResolvedTheme) -> Color {
        switch self {
        case .loading: theme.headerInactiveIcon
        case .ready: Color.green
        case .warning: Color.orange
        case .error: Color.red.opacity(0.92)
        }
    }

    func badgeForeground(theme: NookResolvedTheme) -> Color {
        switch self {
        case .loading: theme.primaryLabel.opacity(0.9)
        case .ready: Color.green.opacity(0.95)
        case .warning: Color.orange.opacity(0.95)
        case .error: Color.red.opacity(0.95)
        }
    }

    func badgeBackground(theme: NookResolvedTheme) -> Color {
        switch self {
        case .loading: theme.subtleFill.opacity(0.55)
        case .ready: Color.green.opacity(0.14)
        case .warning: Color.orange.opacity(0.14)
        case .error: Color.red.opacity(0.14)
        }
    }
}

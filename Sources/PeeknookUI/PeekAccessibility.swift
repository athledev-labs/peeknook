// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Reusable accessibility conventions for Peeknook's shared components. Apply these instead of
/// hand-rolling `accessibility*` on each view so the command bar, pills, skeletons, and failure
/// card expose consistent VoiceOver semantics. New Home/Settings/Setup/History controls should go
/// through these helpers rather than ad-hoc modifiers.
extension View {
    /// Hide purely decorative imagery (glyphs that duplicate an adjacent label) from VoiceOver.
    func peekDecorative() -> some View {
        accessibilityHidden(true)
    }

    /// Collapse a subtree into one actionable control with an explicit label (and optional hint).
    /// Use for icon+text buttons whose visual layout would otherwise read as several elements.
    func peekAction(label: String, hint: String? = nil) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(label))
            .modifier(PeekAccessibilityHint(hint: hint))
    }

    /// Announce a transient busy region (skeletons, shimmer placeholders) as a single status
    /// element instead of exposing its decorative geometry.
    func peekLoading(_ label: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityLabel(Text(label))
    }
}

private struct PeekAccessibilityHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(Text(hint))
        } else {
            content
        }
    }
}

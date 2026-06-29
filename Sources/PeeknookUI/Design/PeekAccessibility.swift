// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Stable `accessibilityIdentifier` values shared by XCUITest and VoiceOver. English UI copy can
/// localize without breaking UI tests that query these ids.
enum PeekTestID {
    static let capture = "peeknook.capture"
    static let brief = "peeknook.brief"
    static let done = "peeknook.done"
    static let newChat = "peeknook.newChat"
    static let stats = "peeknook.stats"
    static let pastChats = "peeknook.pastChats"
    static let showGreeting = "peeknook.settings.showGreeting"
    static let cameraPreview = "peeknook.cameraPreview"
    static let captionSurface = "peeknook.captionSurface"
}

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
        .accessibilityLabel(Text(LocalizedStringKey(label), bundle: .module))
        .modifier(PeekAccessibilityHint(hint: hint))
    }

    /// Announce a transient busy region (skeletons, shimmer placeholders) as a single status
    /// element instead of exposing its decorative geometry.
    func peekLoading(_ label: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityLabel(Text(LocalizedStringKey(label), bundle: .module))
    }

    /// Expose a custom switch row as one VoiceOver toggle: a single element carrying the on/off
    /// value and the `.isToggle` trait, flipped by a single activation action. Apply to the whole
    /// row — it replaces the row's children, so the visual pill stays a plain mouse tap target
    /// without surfacing as a second, redundant element.
    func peekToggle(
        label: String,
        isOn: Bool,
        hint: String? = nil,
        testIdentifier: String? = nil,
        toggle: @escaping () -> Void
    ) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isToggle)
        .accessibilityLabel(Text(LocalizedStringKey(label), bundle: .module))
        .accessibilityValue(Text(LocalizedStringKey(isOn ? "On" : "Off"), bundle: .module))
            // Explicit `.default`: this is the activation VoiceOver fires on double-tap for the
            // switch. (The parameterless form already defaults to `.default`; named for clarity.)
            .accessibilityAction(.default) { toggle() }
            .modifier(PeekAccessibilityHint(hint: hint))
            .modifier(PeekTestIdentifierModifier(identifier: testIdentifier))
    }

    /// Attach a stable identifier for XCUITest without changing the VoiceOver label.
    func peekTestIdentifier(_ identifier: String?) -> some View {
        modifier(PeekTestIdentifierModifier(identifier: identifier))
    }
}

private struct PeekTestIdentifierModifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct PeekAccessibilityHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(Text(LocalizedStringKey(hint), bundle: .module))
        } else {
            content
        }
    }
}

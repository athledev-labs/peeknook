// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

/// Shared pointer-hover motion for glass pills, toolbar buttons, and link rows.
/// Inject via ``EnvironmentValues/peekHoverMotion`` to customize per surface later.
struct PeekHoverMotion: Sendable, Equatable {
    var scale: CGFloat
    var springResponse: Double
    var springDamping: Double

    init(
        scale: CGFloat = 1.012,
        springResponse: Double = 0.26,
        springDamping: Double = 0.86
    ) {
        self.scale = scale
        self.springResponse = springResponse
        self.springDamping = springDamping
    }

    var animation: Animation {
        .spring(response: springResponse, dampingFraction: springDamping)
    }

    /// Default glass/command controls in the notch panel.
    static let glassPill = PeekHoverMotion(scale: 1.014, springResponse: 0.24, springDamping: 0.84)

    /// Text links and settings rows — lighter lift, no scale emphasis.
    static let link = PeekHoverMotion(scale: 1, springResponse: 0.22, springDamping: 0.88)

    /// Suggestion and chip-style pills with a touch more presence.
    static let chip = PeekHoverMotion(scale: 1.018, springResponse: 0.28, springDamping: 0.82)
}

private struct PeekHoverMotionKey: EnvironmentKey {
    static let defaultValue = PeekHoverMotion.glassPill
}

extension EnvironmentValues {
    var peekHoverMotion: PeekHoverMotion {
        get { self[PeekHoverMotionKey.self] }
        set { self[PeekHoverMotionKey.self] = newValue }
    }
}

// MARK: - Modifiers

private struct PeekHoverFeedbackModifier: ViewModifier {
    @Environment(\.peekHoverMotion) private var defaultMotion
    @Binding var isHovered: Bool
    var motion: PeekHoverMotion?
    var enabled: Bool

    private var resolved: PeekHoverMotion { motion ?? defaultMotion }

    func body(content: Content) -> some View {
        content
            .scaleEffect(enabled && isHovered && resolved.scale != 1 ? resolved.scale : 1)
            .animation(resolved.animation, value: isHovered)
            .onHover { hovering in
                guard enabled else { return }
                isHovered = hovering
            }
    }
}

private struct PeekHoverRowHighlightModifier: ViewModifier {
    @Environment(\.nookResolvedTheme) private var theme
    @Environment(\.peekHoverMotion) private var motion
    let isHovered: Bool
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(theme.subtleFill.opacity(isHovered ? 0.34 : 0))
            }
            .animation(motion.animation, value: isHovered)
    }
}

extension View {
    /// Tracks pointer hover and applies the shared spring scale feedback.
    func peekHoverFeedback(
        _ isHovered: Binding<Bool>,
        motion: PeekHoverMotion? = nil,
        enabled: Bool = true
    ) -> some View {
        modifier(
            PeekHoverFeedbackModifier(
                isHovered: isHovered,
                motion: motion,
                enabled: enabled
            )
        )
    }

    /// Subtle row fill for link-style settings and list actions.
    func peekHoverRowHighlight(_ isHovered: Bool, cornerRadius: CGFloat = 6) -> some View {
        modifier(PeekHoverRowHighlightModifier(isHovered: isHovered, cornerRadius: cornerRadius))
    }
}

// MARK: - Foreground helpers

enum PeekHoverForeground {
    static func glassLabel(
        isHovered: Bool,
        prominent: Bool,
        theme: NookResolvedTheme
    ) -> Color {
        if prominent {
            return Color.accentColor.opacity(isHovered ? 1 : 0.9)
        }
        return isHovered
            ? theme.primaryLabel.opacity(0.94)
            : theme.secondaryLabel
    }

    static func dropdownLabel(isHovered: Bool, theme: NookResolvedTheme) -> Color {
        isHovered ? theme.primaryLabel.opacity(0.92) : theme.secondaryLabel
    }

    static func dropdownIcon(isHovered: Bool, theme: NookResolvedTheme) -> Color {
        isHovered ? theme.secondaryLabel : theme.tertiaryLabel
    }
}

// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

/// Per-command liquid glass. On the dark notch panel the pill is white-tinted (material alone blurs to
/// nothing); on a light panel a white tint is invisible, so it switches to a dark frost with a hairline
/// border so the pill still reads. Dark-mode rendering is unchanged.
struct PeekCommandPillGlass: View {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 7
    var isHovered: Bool = false
    var prominent: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if prominent {
                shape.fill(Color.accentColor.opacity(isHovered ? 0.22 : 0.16))
                shape.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
            } else if colorScheme == .light {
                // White-on-white vanishes, so darken the pill instead and lean on a hairline border,
                // the way macOS light-mode controls read.
                shape.fill(Color.black.opacity(isHovered ? 0.08 : 0.05))
                shape.strokeBorder(Color.black.opacity(isHovered ? 0.18 : 0.12), lineWidth: 0.5)
            } else {
                shape.fill(Color.white.opacity(isHovered ? 0.13 : 0.09))
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.26 : 0.18),
                            Color.white.opacity(0.05),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.42 : 0.3),
                            Color.white.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
            }
        }
    }
}

struct PeekGlassSurface: ViewModifier {
    @Environment(\.peekHoverMotion) private var motion
    var cornerRadius: CGFloat = 7
    var isHovered: Bool = false
    var prominent: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                PeekCommandPillGlass(
                    cornerRadius: cornerRadius,
                    isHovered: isHovered,
                    prominent: prominent
                )
                .animation(motion.animation, value: isHovered)
                .animation(motion.animation, value: prominent)
            }
            // Clip any rectangular Button/tint backdrop so prominent accent stays inside the squircle.
            .clipShape(shape)
    }
}

extension View {
    func peekGlass(
        cornerRadius: CGFloat = 7,
        isHovered: Bool = false,
        prominent: Bool = false
    ) -> some View {
        modifier(PeekGlassSurface(cornerRadius: cornerRadius, isHovered: isHovered, prominent: prominent))
    }
}

// SPDX-License-Identifier: Apache-2.0

import NookApp
import SwiftUI

/// Per-command liquid glass — visible on the notch's black panel (material alone blurs to nothing).
struct PeekCommandPillGlass: View {
    var cornerRadius: CGFloat = 7
    var isHovered: Bool = false
    var prominent: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
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
            if prominent {
                shape.fill(Color.accentColor.opacity(isHovered ? 0.18 : 0.12))
            }
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
        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
    }
}

struct PeekGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 7
    var isHovered: Bool = false
    var prominent: Bool = false

    func body(content: Content) -> some View {
        content.background {
            PeekCommandPillGlass(
                cornerRadius: cornerRadius,
                isHovered: isHovered,
                prominent: prominent
            )
        }
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

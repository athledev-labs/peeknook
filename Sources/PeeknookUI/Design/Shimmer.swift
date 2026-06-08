// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

/// A soft light band that sweeps left→right across content, masked to the content's shape.
/// Used for "analyzing" loading states, premium feel without an external animation library.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = 0
    /// Band width as a fraction of the content width.
    var bandFraction: CGFloat = 0.35
    var duration: Double = 1.25

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                let width = geo.size.width
                let band = max(48, width * bandFraction)
                LinearGradient(
                    colors: [.clear, .white.opacity(0.75), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                // Travel from just off the left edge to just past the right edge.
                .offset(x: -band + (width + band) * phase)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
            .mask(content)
        )
        .onAppear {
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

extension View {
    /// Sweep a shimmer highlight across this view while it's on screen.
    func shimmering(bandFraction: CGFloat = 0.35, duration: Double = 1.25) -> some View {
        modifier(Shimmer(bandFraction: bandFraction, duration: duration))
    }
}

/// A shimmering status label for a real pipeline stage (capturing / loading / reading).
struct StageLabel: View {
    @Environment(\.nookResolvedTheme) private var theme
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryLabel)
            .shimmering()
            .peekLoading(text)
    }
}

/// Shimmering skeleton "answer" lines shown while the model is analyzing the capture.
struct AnalyzingSkeleton: View {
    @Environment(\.nookResolvedTheme) private var theme
    private let fractions: [CGFloat] = [0.94, 0.8, 0.56]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fractions.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.tertiaryLabel.opacity(0.2))
                        .frame(width: geo.size.width * fractions[index], height: 10)
                }
            }
            .shimmering()
        }
        // 3 bars (10pt) + 2 gaps (8pt) = 46pt.
        .frame(height: 46)
        .frame(maxWidth: .infinity, alignment: .leading)
        .peekLoading("Analyzing the capture")
    }
}

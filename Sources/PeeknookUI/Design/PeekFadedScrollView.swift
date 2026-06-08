// SPDX-License-Identifier: Apache-2.0

import SwiftUI

private struct PeekScrollFadeEdges: Equatable {
    var top = false
    var bottom = false
}

/// Vertical scroll region with top/bottom fade hints when content overflows `maxHeight`.
struct PeekFadedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content

    @State private var fades = PeekScrollFadeEdges()

    private let fadeHeight: CGFloat = 12

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .frame(maxHeight: maxHeight)
        .onScrollGeometryChange(for: PeekScrollFadeEdges.self) { geometry in
            let offsetY = max(0, geometry.contentOffset.y)
            let visibleBottom = offsetY + geometry.containerSize.height
            let contentHeight = geometry.contentSize.height
            return PeekScrollFadeEdges(
                top: offsetY > 1,
                bottom: visibleBottom < contentHeight - 1
            )
        } action: { _, newValue in
            fades = newValue
        }
        .mask(scrollFadeMask)
    }

    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fades.top ? fadeHeight : 0)

            Rectangle().fill(.black)

            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fades.bottom ? fadeHeight : 0)
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Standard notch scroll container. Hides macOS overlay scroll indicators so content
/// (especially trailing actions) is never covered — matches Settings and drill-in surfaces.
/// Prefer ``PeekFadedScrollView`` when the region has a max height and needs edge fades.
struct PeekScrollView<Content: View>: View {
    var axes: Axis.Set
    @ViewBuilder var content: () -> Content

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: @escaping () -> Content) {
        self.axes = axes
        self.content = content
    }

    var body: some View {
        ScrollView(axes, showsIndicators: false) {
            content()
        }
    }
}

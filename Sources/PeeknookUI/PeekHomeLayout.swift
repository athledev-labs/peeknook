// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

/// Shared expanded-home layout helpers. Horizontal gutter is applied once by
/// ``NookExpandedView`` in contentColumn mode — host rows only need vertical insets.
@MainActor
enum PeekHomeLayout {
    /// Edge-aligned row inside the expanded content column.
    static func insetRow<V: View>(
        _ content: V,
        insets: NookContentInsets,
        alignment: Alignment = .leading,
        top: CGFloat = 0,
        includeBottomInset: Bool = false
    ) -> some View {
        content
            .padding(.top, top)
            .padding(.bottom, includeBottomInset ? insets.bottom : 0)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// Fully scrollable surface (stats drill-ins, archive list).
    static func contentColumn<V: View>(
        _ content: V,
        insets: NookContentInsets,
        top: CGFloat = 8,
        bottom: CGFloat = 0
    ) -> some View {
        content
            .padding(.top, top)
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Pinned bottom command row — same width as the top bar / settings rows.
    static func commandRow<V: View>(
        _ content: V,
        insets: NookContentInsets,
        top: CGFloat = 0,
        includeBottomInset: Bool = false
    ) -> some View {
        insetRow(content, insets: insets, top: top, includeBottomInset: includeBottomInset)
    }
}

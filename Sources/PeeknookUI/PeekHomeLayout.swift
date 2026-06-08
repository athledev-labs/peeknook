// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import SwiftUI

/// Shared expanded-home layout helpers. Aligns Peeknook with OpenNook's LayoutNook pattern:
/// read `nookContentInsets` instead of stacking `.padding(.horizontal, …)` on the home root.
enum PeekHomeLayout {
    static func contentColumn<V: View>(
        _ content: V,
        insets: NookContentInsets,
        top: CGFloat = 8,
        bottom: CGFloat = 0
    ) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }

    static func bottomCommandRow<V: View>(
        _ content: V,
        insets: NookContentInsets,
        top: CGFloat = 0
    ) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .padding(.top, top)
            .padding(.bottom, insets.bottom)
    }

    /// Bottom row when the parent column already applied `nookContentInsets` horizontally.
    static func anchoredBottomRow<V: View>(
        _ content: V,
        bottomInset: CGFloat,
        top: CGFloat = 0
    ) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, top)
            .padding(.bottom, bottomInset)
    }
}

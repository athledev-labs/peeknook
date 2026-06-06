// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Localization foundation for `PeeknookUI`.
///
/// All user-facing strings in this module live in `Resources/Localizable.xcstrings` (a String
/// Catalog). Because this is a library target — not the app — SwiftUI's default `Text("literal")`
/// would resolve against `Bundle.main`, missing the module catalog. Route shared-component strings
/// through `Text(peek:)` / `PeekLocalized(_:)` so they resolve against `Bundle.module` instead.
///
/// Convention for new Home/Settings/Setup/History controls:
/// - Prefer `Text(peek: "Some label")` over `Text("Some label")` for visible copy.
/// - For computed/interpolated strings shown to the user, use `PeekLocalized(_:)`.
/// - Keep keys human-readable English (they double as the source value and the fallback).
/// - Xcode extracts new keys into the catalog on build; add translations there, never in code.
extension Text {
    /// Localized `Text` resolved against this module's String Catalog.
    init(peek key: LocalizedStringKey) {
        self.init(key, bundle: .module)
    }
}

/// Localized `String` resolved against this module's String Catalog — for interpolation into
/// `help(_:)`, accessibility labels, or non-`Text` APIs.
func PeekLocalized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

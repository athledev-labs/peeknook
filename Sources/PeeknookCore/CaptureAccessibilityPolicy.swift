// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure logic for Accessibility least-privilege: skip secure/password fields.
public enum CaptureAccessibilityPolicy: Sendable {
    public static let secureTextSubrole = "AXSecureTextField"

    public static func isSecureSubrole(_ subrole: String?) -> Bool {
        guard let subrole else { return false }
        return subrole == secureTextSubrole
    }

    public static func isSecureRoleDescription(_ description: String?) -> Bool {
        guard let description else { return false }
        let lower = description.lowercased()
        return lower.contains("password") || lower.contains("secure")
    }

    public static func shouldSkipAccessibilityText(subrole: String?, roleDescription: String?) -> Bool {
        isSecureSubrole(subrole) || isSecureRoleDescription(roleDescription)
    }
}

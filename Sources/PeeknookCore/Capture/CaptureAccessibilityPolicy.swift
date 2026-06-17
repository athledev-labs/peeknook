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

    /// Whether an accessibility node's VALUE must be dropped before it leaves the Mac (the node keeps
    /// its role and label, so the structure stays legible, but the value is replaced with a marker).
    /// True for the secure-text subrole and for any role/subrole/role-description that reads as a
    /// password or secure field — a stricter, value-level cousin of ``shouldSkipAccessibilityText`` used
    /// by the accessibility-tree ground, which keeps the surrounding hierarchy rather than skipping the
    /// node entirely.
    public static func shouldRedactValue(role: String?, subrole: String?, roleDescription: String?) -> Bool {
        if isSecureSubrole(subrole) { return true }
        if isSecureRoleDescription(roleDescription) { return true }
        if let role, isSecureRoleDescription(role) { return true }
        return false
    }
}

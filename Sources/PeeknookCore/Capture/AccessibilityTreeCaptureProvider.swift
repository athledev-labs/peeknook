// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Accessibility-tree ground provider: a one-shot `CaptureProviding`. "Read the focused window's
/// structure" is a single user-triggered action — walk the focused window's AX subtree, drop secure
/// values, serialize a capped outline, redact any leftover secret, hand back a TEXT leg — so it rides
/// the registry's untouched capture seam exactly like a screenshot leg, no live-preview arm needed.
/// The live walk lives behind ``AccessibilityTreeReading``; this type only enforces the trust gate,
/// applies per-node value redaction + outline secret redaction, and shapes the `CaptureResult`
/// (`ground == .accessibilityTree`, outline in `text`, NO image, so the vision gate never trips).
public struct AccessibilityTreeCaptureProvider: CaptureProviding, Sendable {
    private let reader: any AccessibilityTreeReading
    private let cap: AXTreeCap
    /// Injected so BOTH branches (trusted / not) are testable without touching the real
    /// `AXIsProcessTrusted`. Production passes the live check; tests pass a constant.
    private let isTrusted: @Sendable () -> Bool

    public init(
        reader: any AccessibilityTreeReading = AccessibilityTreeCaptureProvider.makeProductionReader(),
        cap: AXTreeCap = .default,
        isTrusted: @escaping @Sendable () -> Bool = AccessibilityTreeCaptureProvider.makeProductionTrustCheck()
    ) {
        self.reader = reader
        self.cap = cap
        self.isTrusted = isTrusted
    }

    /// Registry arm: scope/quick/encoding are screen-image concepts the accessibility ground ignores.
    /// Gates on accessibility trust, walks the focused window, redacts, and returns the outline as a
    /// text-only `CaptureResult`.
    public func capture(
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult {
        _ = (scope, quick, encoding)   // image concepts; the accessibility ground ignores all three
        guard isTrusted() else {
            throw CaptureError.permissionRequired(CapturePermission.accessibility.displayName)
        }
        let snapshot = try await reader.readFocusedWindowTree(cap: cap)
        // Per-NODE value redaction first: a secure/password node keeps its role + label but loses its
        // value, so the structure stays legible while the secret never reaches the outline.
        let redactedSnapshot = Self.redactingSecureValues(in: snapshot)
        let serialized = AXTreeSerializer.serialize(redactedSnapshot, cap: cap)
        // Then SPAN redaction over the whole outline: a token (JWT, sk-…) sitting in a NON-secure field
        // is masked by the same heuristics that gate every other egress, so a leaked secret in a plain
        // value never rides the leg either.
        let outline = SensitiveContentPolicy().redactedForRemoteInference(text: serialized.outline).text
        let trimmed = outline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CaptureError.noContent
        }
        return CaptureResult(
            text: trimmed,
            sourceLabel: "Accessibility tree",
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            screenshotBase64: nil,   // a structure outline carries no image — keep hasVision false
            ground: .accessibilityTree
        )
    }

    /// Replaces every secure node's value with the redaction marker, recursively, keeping role/label and
    /// the surrounding hierarchy intact. Pure value-tree transform; the platform walk never sees it.
    static func redactingSecureValues(in snapshot: AXTreeSnapshot) -> AXTreeSnapshot {
        AXTreeSnapshot(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            root: redactingSecureValues(in: snapshot.root),
            truncated: snapshot.truncated
        )
    }

    private static func redactingSecureValues(in node: AXTreeNode) -> AXTreeNode {
        let redactValue = node.value != nil && CaptureAccessibilityPolicy.shouldRedactValue(
            role: node.role, subrole: node.subrole, roleDescription: node.label
        )
        return AXTreeNode(
            role: node.role,
            subrole: node.subrole,
            label: node.label,
            value: redactValue ? SensitiveContentPolicy.redactionToken : node.value,
            children: node.children.map(redactingSecureValues(in:))
        )
    }

    /// The production reader (real `ApplicationServices` walk on Apple platforms; a clearly-failing
    /// stand-in elsewhere so non-mac builds compile). Wired in `PeeknookDependencies.production()`.
    public static func makeProductionReader() -> any AccessibilityTreeReading {
        #if canImport(ApplicationServices) && canImport(AppKit)
        return AXUIElementTreeReader()
        #else
        return UnavailableAccessibilityTreeReader()
        #endif
    }

    /// The production trust check (real `AXIsProcessTrusted` on Apple platforms; always-false elsewhere
    /// so a non-mac build never claims the API is granted).
    public static func makeProductionTrustCheck() -> @Sendable () -> Bool {
        #if canImport(ApplicationServices)
        return { AXIsProcessTrusted() }
        #else
        return { false }
        #endif
    }
}

// MARK: - Production walk (isolated; the only platform-coupled code)

#if canImport(ApplicationServices) && canImport(AppKit)

/// Live focused-window accessibility walk via `AXUIElement`. The ONLY hardware/TCC-coupled type in this
/// ground — not unit-testable, exercised only on a real Mac with Accessibility granted. Everything above
/// it (the trust gate, the per-node + outline redaction, the serializer, the provider policy, the
/// settings gate) is covered by stub-driven tests.
///
/// NOTE: this live walk is the one piece that cannot be verified in `swift test`; it is structured to
/// stay off every other code path until the user opts in AND a capture actually resolves to this ground.
struct AXUIElementTreeReader: AccessibilityTreeReading {
    func readFocusedWindowTree(cap: AXTreeCap) async throws -> AXTreeSnapshot {
        let system = AXUIElementCreateSystemWide()

        // The focused application, then its focused window — the user's current surface.
        guard let app = Self.copyElement(system, kAXFocusedApplicationAttribute) else {
            throw CaptureError.failed("No focused application is available to read.")
        }
        guard let window = Self.copyElement(app, kAXFocusedWindowAttribute)
            ?? Self.copyElement(app, kAXMainWindowAttribute) else {
            throw CaptureError.failed("No focused window is available to read.")
        }

        let appName = Self.copyString(app, kAXTitleAttribute)
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
        let windowTitle = Self.copyString(window, kAXTitleAttribute)

        var nodeCount = 0
        let root = Self.walk(window, depth: 0, cap: cap, nodeCount: &nodeCount)
        let truncated = nodeCount >= cap.maxNodes
        return AXTreeSnapshot(appName: appName, windowTitle: windowTitle, root: root, truncated: truncated)
    }

    /// Recursively build a value node from an `AXUIElement`, bounded by the node/depth caps so the live
    /// walk itself can never balloon. Secure values are NOT special-cased here — the provider redacts
    /// them from the value tree afterward, keeping the platform path purely about reading.
    private static func walk(_ element: AXUIElement, depth: Int, cap: AXTreeCap, nodeCount: inout Int) -> AXTreeNode {
        nodeCount += 1
        let role = copyString(element, kAXRoleAttribute) ?? "AXUnknown"
        let subrole = copyString(element, kAXSubroleAttribute)
        let label = copyString(element, kAXTitleAttribute)
            ?? copyString(element, kAXDescriptionAttribute)
        let value = copyString(element, kAXValueAttribute)

        var children: [AXTreeNode] = []
        if depth < cap.maxDepth, nodeCount < cap.maxNodes,
           let raw = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in raw {
                if nodeCount >= cap.maxNodes { break }
                children.append(walk(child, depth: depth + 1, cap: cap, nodeCount: &nodeCount))
            }
        }
        return AXTreeNode(role: role, subrole: subrole, label: label, value: value, children: children)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif

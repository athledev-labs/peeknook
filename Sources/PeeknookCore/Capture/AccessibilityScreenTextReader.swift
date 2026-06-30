// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(ApplicationServices) && canImport(AppKit)
import ApplicationServices
import AppKit

/// Reads the on-screen TEXT of the frozen caption target from its accessibility tree — the cheap, exact,
/// pixel-free path for text surfaces (articles, chat, some players' caption tracks). Walks the target
/// app's focused/main window bounded by ``AXTreeCap``, collects the static-text values, DROPS secure
/// fields (``CaptureAccessibilityPolicy``) and masks any leftover secret (``SensitiveContentPolicy``)
/// before the text could ever translate — the same redaction the one-shot accessibility ground applies.
///
/// Carries no geometry (the AX value tree has none here), so the snapshot's lines have nil rects and the
/// extractor scores them structurally. The ONLY hardware/TCC-coupled type in this reader; isolated like
/// ``AXUIElementTreeReader`` and verified on-device, while the policy that consumes its output is tested.
///
/// LIMITATION — not yet production-wired: this walks the target app's FOCUSED/MAIN window by `pid`, not
/// the frozen `target.windowID`. There is no clean public `CGWindowID -> AXUIElement` bridge, so in a
/// multi-window app this could drift to a different window than the one armed — a bounded-capture
/// violation. Until that pinning exists, ``PeeknookDependencies/makeProductionScreenTextReader(locale:)``
/// uses OCR alone (which re-resolves the frozen window every poll); this reader + ``CompositeScreenTextReader``
/// stay tested-but-unwired.
struct AccessibilityScreenTextReader: OnScreenTextReading {
    private let cap: AXTreeCap
    private let isTrusted: @Sendable () -> Bool
    private let redactor = SensitiveContentPolicy()

    init(
        cap: AXTreeCap = .default,
        isTrusted: @escaping @Sendable () -> Bool = AccessibilityTreeCaptureProvider.makeProductionTrustCheck()
    ) {
        self.cap = cap
        self.isTrusted = isTrusted
    }

    func readText(target: ScreenTextTarget) async throws -> ScreenTextSnapshot {
        guard isTrusted() else {
            throw CaptureError.permissionRequired(CapturePermission.accessibility.displayName)
        }
        let app = AXUIElementCreateApplication(target.pid)
        guard let window = Self.copyElement(app, kAXFocusedWindowAttribute)
            ?? Self.copyElement(app, kAXMainWindowAttribute) else {
            // The target app exposes no window to read — an empty read, not a hard failure, so the source
            // simply escalates to OCR / rides audio rather than ending the caption.
            return .empty(source: .accessibility, appName: target.appName, windowTitle: target.windowTitle)
        }
        var nodeCount = 0
        var texts: [String] = []
        Self.collectText(window, depth: 0, cap: cap, nodeCount: &nodeCount, into: &texts)

        let lines = texts.compactMap { raw -> ScreenTextLine? in
            let redacted = redactor.redactedForRemoteInference(text: raw).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return redacted.isEmpty ? nil : ScreenTextLine(text: redacted)
        }
        return ScreenTextSnapshot(
            appName: target.appName,
            windowTitle: target.windowTitle,
            lines: lines,
            source: .accessibility
        )
    }

    /// Walk the subtree collecting non-secure static text, bounded by the node/depth caps so the live
    /// walk can never balloon. Secure nodes (password fields) are skipped value-and-all.
    private static func collectText(
        _ element: AXUIElement,
        depth: Int,
        cap: AXTreeCap,
        nodeCount: inout Int,
        into texts: inout [String]
    ) {
        guard nodeCount < cap.maxNodes, depth <= cap.maxDepth else { return }
        nodeCount += 1

        let role = copyString(element, kAXRoleAttribute)
        let subrole = copyString(element, kAXSubroleAttribute)
        let roleDescription = copyString(element, kAXRoleDescriptionAttribute)
        let isSecure = CaptureAccessibilityPolicy.shouldRedactValue(
            role: role, subrole: subrole, roleDescription: roleDescription
        )
        if !isSecure, let value = copyString(element, kAXValueAttribute) {
            texts.append(value)
        }

        guard depth < cap.maxDepth, nodeCount < cap.maxNodes,
              let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            if nodeCount >= cap.maxNodes { break }
            collectText(child, depth: depth + 1, cap: cap, nodeCount: &nodeCount, into: &texts)
        }
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

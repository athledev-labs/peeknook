// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The read arm of the accessibility-tree ground: walk the focused window's AX subtree and hand back a
/// pure value snapshot (roles, labels, values, hierarchy). Isolated behind this protocol so the
/// provider's POLICY (cap the walk, drop secure values, serialize to a text leg, never claim vision) is
/// unit-testable with a stub while the real `ApplicationServices` `AXUIElement` walk lives behind the
/// production conformer. The reader returns a tree of `Sendable` value nodes; turning it into a
/// `CaptureResult` is the provider's job, kept out of the platform path so the seam stays fakeable.
public protocol AccessibilityTreeReading: Sendable {
    /// Walk the focused window's accessibility subtree, bounded by `cap`. Throws on missing trust or an
    /// unavailable accessibility API. The walk itself enforces the node/depth caps so a runaway tree
    /// never balloons memory; the serializer enforces the character caps.
    func readFocusedWindowTree(cap: AXTreeCap) async throws -> AXTreeSnapshot
}

// MARK: - Pure value types

/// One node of a captured accessibility subtree: its role, optional subrole/label/value, and children.
/// A pure `Sendable` value — never an `AXUIElement` — so the whole snapshot crosses concurrency
/// boundaries and is trivially constructible in tests.
public struct AXTreeNode: Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let label: String?
    public let value: String?
    public let children: [AXTreeNode]

    public init(
        role: String,
        subrole: String? = nil,
        label: String? = nil,
        value: String? = nil,
        children: [AXTreeNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.children = children
    }
}

/// A captured accessibility snapshot of the focused window: its owning app/window identity, the root
/// node, and whether any cap (nodes, depth, value chars, total chars) tripped during the walk or
/// serialization. `truncated` is the honest "you are not seeing all of it" signal.
public struct AXTreeSnapshot: Sendable, Equatable {
    public let appName: String?
    public let windowTitle: String?
    public let root: AXTreeNode
    public let truncated: Bool

    public init(appName: String? = nil, windowTitle: String? = nil, root: AXTreeNode, truncated: Bool = false) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.root = root
        self.truncated = truncated
    }
}

/// Hard caps on the accessibility walk and serialization. Conservative by design — an AX subtree can be
/// enormous, and this ground rides as text into the prompt, so it must stay bounded. Every cap is a
/// hard limit, not a hint; tripping any one sets `AXTreeSnapshot.truncated` / `AXTreeSerializer`'s
/// truncation marker.
public struct AXTreeCap: Sendable, Equatable {
    /// Maximum number of nodes emitted across the whole tree.
    public let maxNodes: Int
    /// Maximum depth descended from the root (root is depth 0).
    public let maxDepth: Int
    /// Maximum characters kept from a single node's value before it is elided.
    public let maxValueChars: Int
    /// Hard cap on the serialized outline's total length, regardless of node/depth caps.
    public let maxTotalChars: Int

    public init(maxNodes: Int = 400, maxDepth: Int = 12, maxValueChars: Int = 200, maxTotalChars: Int = 12_000) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.maxValueChars = maxValueChars
        self.maxTotalChars = maxTotalChars
    }

    /// Conservative shared default used by the provider and tests.
    public static let `default` = AXTreeCap()
}

// MARK: - Serializer (pure)

/// Turns an ``AXTreeSnapshot`` into a capped, indented `role(label)=value` outline. Pure and
/// deterministic — no platform calls — so the caps and the truncation signal are unit-tested directly.
/// Sets ``Result/truncated`` when any cap trips (the snapshot's own flag, the node cap, or the total
/// character cap), and HARD-caps the total length so a single oversized value can never blow the budget.
public enum AXTreeSerializer: Sendable {
    public struct Result: Sendable, Equatable {
        public let outline: String
        public let truncated: Bool

        public init(outline: String, truncated: Bool) {
            self.outline = outline
            self.truncated = truncated
        }
    }

    /// The fixed marker appended when the outline is cut short by a cap.
    public static let truncationMarker = "… (truncated)"

    public static func serialize(_ snapshot: AXTreeSnapshot, cap: AXTreeCap = .default) -> Result {
        var lines: [String] = []
        var nodeCount = 0
        var capTripped = snapshot.truncated

        func walk(_ node: AXTreeNode, depth: Int) {
            guard nodeCount < cap.maxNodes else { capTripped = true; return }
            guard depth <= cap.maxDepth else { capTripped = true; return }
            nodeCount += 1
            lines.append(line(for: node, depth: depth, cap: cap, capTripped: &capTripped))
            for child in node.children {
                guard nodeCount < cap.maxNodes else { capTripped = true; return }
                walk(child, depth: depth + 1)
            }
        }
        walk(snapshot.root, depth: 0)

        var outline = lines.joined(separator: "\n")
        if outline.count > cap.maxTotalChars {
            // Hard cap: cut to the budget and mark truncated, regardless of which caps tripped above.
            let end = outline.index(outline.startIndex, offsetBy: cap.maxTotalChars)
            outline = String(outline[outline.startIndex..<end])
            capTripped = true
        }
        if capTripped {
            outline = outline.isEmpty ? truncationMarker : outline + "\n" + truncationMarker
        }
        return Result(outline: outline, truncated: capTripped)
    }

    /// One indented `role(label)=value` line. The value is elided to `maxValueChars`; a redacted value
    /// (the provider replaces it with a marker before serializing) passes through verbatim.
    private static func line(for node: AXTreeNode, depth: Int, cap: AXTreeCap, capTripped: inout Bool) -> String {
        let indent = String(repeating: "  ", count: depth)
        var text = node.role
        if let label = node.label, !label.isEmpty {
            text += "(\(label))"
        }
        if let value = node.value, !value.isEmpty {
            if value.count > cap.maxValueChars {
                let end = value.index(value.startIndex, offsetBy: cap.maxValueChars)
                text += "=\(value[value.startIndex..<end])…"
                capTripped = true
            } else {
                text += "=\(value)"
            }
        }
        return indent + text
    }
}

// MARK: - Stand-in for non-Apple builds

/// Stand-in for platforms without the accessibility API (so the package compiles everywhere). Always
/// throws — the ground simply has no accessibility tree to walk on those targets.
struct UnavailableAccessibilityTreeReader: AccessibilityTreeReading {
    func readFocusedWindowTree(cap: AXTreeCap) async throws -> AXTreeSnapshot {
        _ = cap
        throw CaptureError.failed("Reading the accessibility tree requires macOS with the accessibility API.")
    }
}

// MARK: - Test-only stub

/// Deterministic accessibility-tree double for unit tests and the UI test host. Returns a scripted
/// snapshot (or throws a scripted error) without touching the live accessibility API, mirroring
/// ``StubSystemAudioTranscriber`` / ``StubClipboardReader``.
public struct StubAccessibilityTreeReader: AccessibilityTreeReading {
    public var snapshot: AXTreeSnapshot
    public var error: CaptureError?

    public init(snapshot: AXTreeSnapshot = StubAccessibilityTreeReader.sampleSnapshot, error: CaptureError? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    public func readFocusedWindowTree(cap: AXTreeCap) async throws -> AXTreeSnapshot {
        _ = cap
        if let error { throw error }
        return snapshot
    }

    /// A small representative tree: a window with a heading, a plain text field, and a secure field. The
    /// secure field's value is present in the stub so a test can prove the provider drops it.
    public static let sampleSnapshot = AXTreeSnapshot(
        appName: "Mail",
        windowTitle: "Inbox",
        root: AXTreeNode(
            role: "AXWindow",
            label: "Inbox",
            children: [
                AXTreeNode(role: "AXStaticText", label: "Subject", value: "Project update"),
                AXTreeNode(role: "AXTextField", label: "Search", value: "release notes"),
                AXTreeNode(role: "AXTextField", subrole: "AXSecureTextField", label: "Password", value: "hunter2-secret"),
            ]
        )
    )
}

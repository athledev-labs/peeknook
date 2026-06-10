// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Sparse per-profile module forcing: absent = inherit the global setting (never "off"), so the
/// tolerant-decode discipline holds — an old blob missing this field changes nothing. Only the
/// five user-facing opt-ins are overridable; grounded modules (`screenCapture`/`cameraCapture`/
/// `selectedText`) derive from the profile's grounds and reserved modules aren't shipped, so both
/// are filtered at EVERY boundary (decode AND set) — a corrupt `{"cameraCapture":true}` blob is
/// dropped, it can never decouple a module from its ground.
public struct ModuleOverrides: Codable, Equatable, Sendable {
    public static let overrideEligible: Set<ModuleID> = [
        .webLookup, .voiceInput, .speakAnswers, .saveConversation, .suggestFollowUps,
    ]

    public static let none = ModuleOverrides()

    private var enabled: [ModuleID: Bool]

    public init(_ enabled: [ModuleID: Bool] = [:]) {
        self.enabled = enabled.filter { Self.overrideEligible.contains($0.key) }
    }

    public var isEmpty: Bool { enabled.isEmpty }

    /// The forced value for an eligible module, or nil (inherit global / ineligible).
    public func value(for id: ModuleID) -> Bool? {
        guard Self.overrideEligible.contains(id) else { return nil }
        return enabled[id]
    }

    /// `nil` clears the override (back to inherit). No-op for ineligible modules.
    public mutating func set(_ id: ModuleID, _ on: Bool?) {
        guard Self.overrideEligible.contains(id) else { return }
        enabled[id] = on
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Bool].self)
        var filtered: [ModuleID: Bool] = [:]
        for (key, value) in raw {
            guard let id = ModuleID(rawValue: key), Self.overrideEligible.contains(id) else {
                continue // unknown (future) or ineligible module ids drop, never throw
            }
            filtered[id] = value
        }
        self.enabled = filtered
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: enabled.map { ($0.key.rawValue, $0.value) }))
    }
}

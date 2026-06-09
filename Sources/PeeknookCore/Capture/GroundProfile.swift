// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A named bundle of active grounds + capture behavior. The grouping lens that makes readiness and
/// (later) the command layout ground-aware. In phase 1 the catalog is **code-defined** — only the
/// active profile *id* persists (in ``PeeknookSettings``), so there is no fat persisted blob and no
/// way for the catalog to drift or reset. The `Codable` conformance is forward-compat for the future
/// profile editor (`peeknook.profiles.v1`), and its decode is deliberately **tolerant**: an unknown
/// ground raw value (from a newer build) is dropped rather than throwing and wiping the catalog.
///
/// `commandLayout` (Phase 1.5) and `modelRoles` (Phase 4) are intentionally absent — they land with
/// the types they depend on, and adding a field to a code-defined struct is mechanical.
public struct GroundProfile: Equatable, Sendable, Identifiable {
    public let id: String
    /// `Localizable.xcstrings` KEY (resolved by the UI via `Text(peek:)`), never a resolved string.
    public let displayNameKey: String
    public let symbol: String
    /// The ground whose `CaptureProviding` a capture calls — `activeGrounds` always contains it.
    public let primaryGround: Ground
    public let activeGrounds: Set<Ground>
    public let isBuiltIn: Bool

    public init(
        id: String,
        displayNameKey: String,
        symbol: String,
        primaryGround: Ground,
        activeGrounds: Set<Ground>,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.displayNameKey = displayNameKey
        self.symbol = symbol
        self.primaryGround = primaryGround
        self.activeGrounds = activeGrounds
        self.isBuiltIn = isBuiltIn
    }

    /// Union of the required permissions of every active ground. Supplementary grounds (AX via
    /// `selectedText`) contribute nothing — see ``Ground/requiredPermissions``.
    public var requiredPermissions: Set<CapturePermission> {
        activeGrounds.reduce(into: []) { $0.formUnion($1.requiredPermissions) }
    }
}

// MARK: - Tolerant Codable (forward-compat for the future persisted profile catalog)

extension GroundProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, displayNameKey, symbol, primaryGround, activeGrounds, isBuiltIn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayNameKey = try container.decode(String.self, forKey: .displayNameKey)
        symbol = try container.decode(String.self, forKey: .symbol)
        // Tolerant by design: an unknown raw ground (from a newer build) must NOT throw and reset
        // the whole catalog. Unknown primary falls back to `.screen`; unknown active grounds drop.
        let primaryRaw = try container.decode(String.self, forKey: .primaryGround)
        primaryGround = Ground(rawValue: primaryRaw) ?? .screen
        let groundRaws = try container.decode([String].self, forKey: .activeGrounds)
        var grounds = Set(groundRaws.compactMap(Ground.init(rawValue:)))
        grounds.insert(primaryGround)   // the primary ground is always active
        activeGrounds = grounds
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayNameKey, forKey: .displayNameKey)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(primaryGround.rawValue, forKey: .primaryGround)
        try container.encode(activeGrounds.map(\.rawValue).sorted(), forKey: .activeGrounds)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
    }
}

// MARK: - Built-in catalog (code-defined in phase 1)

public extension GroundProfile {
    /// The shipped default: window/display capture, with Accessibility selected-text as a silent
    /// supplement. `requiredPermissions == [.screenRecording]` (AX never hard-gates), preserving the
    /// "Screen Recording is the only capture gate" behavior while the matrix becomes profile-aware.
    static let screenDefault = GroundProfile(
        id: "screen.default",
        displayNameKey: "Screen",
        symbol: "macwindow",
        primaryGround: .screen,
        activeGrounds: [.screen, .selectedText],
        isBuiltIn: true
    )

    /// Built-in profiles. `camera.study` is added with the camera PR, never speculatively before it.
    static var all: [GroundProfile] { [.screenDefault] }

    /// Resolve a profile id to its built-in, falling back to `screen.default` for an unknown id
    /// (so a stale persisted `activeProfileID` can never strand the user).
    static func builtIn(id: String) -> GroundProfile {
        all.first { $0.id == id } ?? .screenDefault
    }
}

public extension PeeknookSettings {
    /// The active ground profile, resolved from `activeProfileID` (unknown/stale id → `screen.default`).
    var activeProfile: GroundProfile { GroundProfile.builtIn(id: activeProfileID) }
}

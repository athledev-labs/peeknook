// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A portable, shareable preset: one or more ``GroundProfile``s serialized to a self-describing JSON
/// envelope a user can hand to another user. `peeknook.*` only — it never touches `opennook.*` and
/// carries no settings beyond the profiles themselves.
///
/// The whole point is to be IMPORTED from an untrusted source, so every decode path is non-throwing by
/// construction (the same reset-bomb discipline as ``ProfileCatalog``): a malformed or hostile preset
/// degrades to the profiles it CAN read, never crashes and never strands the user's existing catalog.
/// - the `format` marker is checked but a mismatch yields an empty preset, not a throw,
/// - profiles decode element-lossily (one corrupt entry drops; its siblings survive),
/// - unknown grounds drop and unknown fields are ignored (inherited from ``GroundProfile`` decode),
/// - built-in masqueraders (`isBuiltIn == true` or a reserved built-in id) are filtered out,
/// - the array caps at ``ProfileCatalog/maxProfiles`` so a giant preset can't blow up memory.
///
/// Round-trip is LOSSLESS for known fields: `export(_:)` → `import(from:)` returns the same profile
/// content (name, grounds, instruction, template, model binding, module overrides). De-collision with
/// the receiving catalog happens at INSTALL time (``installable(into:)``), not in the wire format, so
/// the serialized bytes stay a faithful copy of the source.
public struct ProfilePreset: Codable, Equatable, Sendable {
    /// Wire marker so an unrelated JSON file (or a future incompatible format) is recognized and
    /// rejected up front instead of half-decoding into something surprising.
    public static let format = "peeknook.profile-preset"
    public static let currentSchemaVersion = 1

    public let format: String
    public let schemaVersion: Int
    public let profiles: [GroundProfile]

    public init(profiles: [GroundProfile]) {
        self.format = Self.format
        self.schemaVersion = Self.currentSchemaVersion
        // Exported profiles are always user content: a built-in masquerader can never ship out.
        self.profiles = profiles.filter { !$0.isBuiltIn }
    }

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, profiles
    }

    /// Element-lossy wrapper: a corrupt profile entry decodes to nil instead of failing the array.
    private struct LossyProfile: Decodable {
        let profile: GroundProfile?
        init(from decoder: Decoder) {
            profile = try? GroundProfile(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.format = (try? c.decode(String.self, forKey: .format)) ?? ""
        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? Self.currentSchemaVersion
        // A wrong/absent format marker means "this isn't one of ours": yield zero profiles rather than
        // trusting arbitrary JSON shaped vaguely like a preset.
        guard self.format == Self.format else {
            self.profiles = []
            return
        }
        let decoded = ((try? c.decode([LossyProfile].self, forKey: .profiles)) ?? [])
            .compactMap(\.profile)
        let builtInIDs = Set(GroundProfile.all.map(\.id))
        var seen = Set<String>()
        var kept: [GroundProfile] = []
        for profile in decoded {
            guard !profile.isBuiltIn, !builtInIDs.contains(profile.id), !seen.contains(profile.id) else {
                continue
            }
            seen.insert(profile.id)
            kept.append(profile)
            if kept.count == ProfileCatalog.maxProfiles { break }
        }
        self.profiles = kept
    }

    // MARK: - Export

    /// Serialize a set of profiles to portable preset JSON. Built-ins are dropped (only user content
    /// ships). Pretty-printed with sorted keys so the file is human-diffable and deterministic.
    public static func export(_ profiles: [GroundProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ProfilePreset(profiles: profiles))
    }

    /// Decode preset bytes into the profiles they contain. NEVER throws on bad input: undecodable
    /// bytes (not even JSON) yield an empty array, mirroring the tolerant container decode.
    public static func `import`(from data: Data) -> [GroundProfile] {
        (try? JSONDecoder().decode(ProfilePreset.self, from: data))?.profiles ?? []
    }

    // MARK: - Install

    /// The preset's profiles rewritten so they can be ADDED to `catalog` without colliding: each gets
    /// a fresh UUID id and `isBuiltIn = false` (defensive — the decode already drops built-ins). Ids
    /// are always re-minted so importing the same preset twice yields two distinct profiles instead of
    /// silently overwriting one. Caps so the merged catalog never exceeds ``ProfileCatalog/maxProfiles``.
    ///
    /// SECURITY: import is the untrusted boundary, so a `.command` ``ToolSpec`` (arbitrary local code
    /// execution) is STRIPPED here — an imported profile can carry a `prompt + instruction + which tool
    /// to expect`, but never an executable. Only an `http` (loopback) tool survives, and it is still
    /// re-validated through ``EndpointURLPolicy`` when the provider runs it. The recipient re-points a
    /// stripped tool at their own binary. See ``ToolSpec/shareableOrStripped``.
    ///
    /// `activeGrounds` is sanitized through the same ``GroundProfile/sanitizedActiveGrounds(_:primary:)``
    /// the edit seam uses, so a hand-crafted preset can never seed a non-foldable ground (e.g. `.camera`
    /// on a screen profile) into the catalog. With this boundary enforcing the invariant, every stored
    /// profile already satisfies it, so a later edit is a pure no-op on grounds.
    public func installable(into catalog: ProfileCatalog) -> [GroundProfile] {
        let room = max(0, ProfileCatalog.maxProfiles - catalog.profiles.count)
        return profiles.prefix(room).map { source in
            GroundProfile(
                id: UUID().uuidString,
                displayNameKey: source.displayNameKey,
                symbol: source.symbol,
                primaryGround: source.primaryGround,
                activeGrounds: GroundProfile.sanitizedActiveGrounds(source.activeGrounds, primary: source.primaryGround),
                isBuiltIn: false,
                displayName: source.displayName,
                instruction: source.instruction,
                promptTemplate: source.promptTemplate,
                modelBinding: source.modelBinding,
                moduleOverrides: source.moduleOverrides,
                toolSpec: source.toolSpec?.shareableOrStripped,
                outputConfig: source.outputConfig
            )
        }
    }
}

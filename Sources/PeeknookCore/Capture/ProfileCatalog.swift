// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The `peeknook.profiles.v1` container: USER profiles only — built-ins are code-defined and never
/// enter the persisted array. Every decode path is non-throwing by construction (the reset-bomb
/// rule: a single bad byte must never strand every user profile):
/// - `schemaVersion` decodes via `try?` (a type-mismatched value degrades to current, not a throw),
/// - profiles decode element-lossily (one corrupt entry drops; its siblings survive),
/// - built-in masqueraders (`isBuiltIn == true` or a built-in id) are filtered out,
/// - duplicate ids de-dupe first-wins, and the array caps at ``maxProfiles``.
public struct ProfileCatalog: Codable, Equatable, Sendable {
    public static let defaultsKey = "peeknook.profiles.v1"
    public static let currentSchemaVersion = 1
    public static let maxProfiles = 50
    public static let empty = ProfileCatalog()

    /// Versions the container, not each profile.
    public var schemaVersion: Int
    public var profiles: [GroundProfile]

    public init(schemaVersion: Int = Self.currentSchemaVersion, profiles: [GroundProfile] = []) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profiles
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
        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? Self.currentSchemaVersion
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
            if kept.count == Self.maxProfiles { break }
        }
        self.profiles = kept
    }
}

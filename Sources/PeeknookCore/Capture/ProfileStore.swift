// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Single owner of the user-profile catalog: every mutation lands here and persists to
/// `peeknook.profiles.v1` immediately (mirroring `PeeknookSettings.save/load`). Built-ins are
/// code-defined and IMMUTABLE — they never enter the persisted array (`update`/`delete` on a
/// built-in id are no-ops; the decode additionally drops masqueraders), so the two shipped
/// profiles can never drift or reset.
@MainActor
@Observable
public final class ProfileStore {
    public private(set) var catalog: ProfileCatalog
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.catalog = Self.load(from: defaults)
    }

    /// Built-ins first, then the user's copies in creation order.
    public var allProfiles: [GroundProfile] { GroundProfile.all + catalog.profiles }

    public func profile(id: String) -> GroundProfile {
        GroundProfile.resolve(id: id, in: catalog.profiles)
    }

    /// Sources a user may duplicate. v1 is screen-grounded only: a camera copy would be a ⌘⇧P
    /// dead-end (the live-camera surface is reachable only via ⌘⇧C and the `cameraStudy` literal).
    public var duplicableBuiltIns: [GroundProfile] {
        GroundProfile.all.filter { $0.primaryGround == .screen }
    }

    /// Copies a screen-grounded profile under a fresh UUID id. Nil when the source is
    /// camera-grounded (guarded at the store, not just the UI) or the catalog is at capacity —
    /// callers surface the refusal instead of holding a phantom profile.
    @discardableResult
    public func duplicate(_ source: GroundProfile, name: String) -> GroundProfile? {
        guard source.primaryGround == .screen else { return nil }
        guard catalog.profiles.count < ProfileCatalog.maxProfiles else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let copy = GroundProfile(
            id: UUID().uuidString,
            displayNameKey: source.displayNameKey,
            symbol: source.symbol,
            primaryGround: source.primaryGround,
            activeGrounds: source.activeGrounds,
            isBuiltIn: false,
            displayName: trimmed.isEmpty ? nil : trimmed,
            instruction: source.instruction,
            modelBinding: source.modelBinding,
            moduleOverrides: source.moduleOverrides
        )
        catalog.profiles.append(copy)
        persist()
        return copy
    }

    /// Replaces a user profile by id. No-op for built-ins or unknown ids.
    public func update(_ profile: GroundProfile) {
        guard !profile.isBuiltIn,
              let index = catalog.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        catalog.profiles[index] = profile
        persist()
    }

    public func rename(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let existing = catalog.profiles.first(where: { $0.id == id }) else { return }
        update(existing.with(
            displayName: trimmed,
            instruction: existing.instruction,
            modelBinding: existing.modelBinding,
            moduleOverrides: existing.moduleOverrides
        ))
    }

    /// Stores the instruction capped at the limit (the read path fully sanitizes — see
    /// `ProfileInstruction.sanitized`); empty clears it.
    public func setInstruction(id: String, _ text: String) {
        guard let existing = catalog.profiles.first(where: { $0.id == id }) else { return }
        let capped = text.isEmpty ? nil : String(text.prefix(ProfileInstruction.maxLength))
        update(existing.with(
            displayName: existing.displayName,
            instruction: capped,
            modelBinding: existing.modelBinding,
            moduleOverrides: existing.moduleOverrides
        ))
    }

    /// `nil` clears the binding (back to the global answer model).
    public func setModelBinding(id: String, _ binding: ProfileModelBinding?) {
        guard let existing = catalog.profiles.first(where: { $0.id == id }) else { return }
        update(existing.with(
            displayName: existing.displayName,
            instruction: existing.instruction,
            modelBinding: binding,
            moduleOverrides: existing.moduleOverrides
        ))
    }

    /// `nil` clears the override (inherit global). Ineligible modules no-op (see ``ModuleOverrides``).
    public func setModuleOverride(id: String, module: ModuleID, enabled: Bool?) {
        guard let existing = catalog.profiles.first(where: { $0.id == id }) else { return }
        var overrides = existing.moduleOverrides
        overrides.set(module, enabled)
        update(existing.with(
            displayName: existing.displayName,
            instruction: existing.instruction,
            modelBinding: existing.modelBinding,
            moduleOverrides: overrides
        ))
    }

    public func clearModuleOverrides(id: String) {
        guard let existing = catalog.profiles.first(where: { $0.id == id }) else { return }
        update(existing.with(
            displayName: existing.displayName,
            instruction: existing.instruction,
            modelBinding: existing.modelBinding,
            moduleOverrides: .none
        ))
    }

    /// Removes a user profile. Returns true when the deleted profile was the active one, so the
    /// caller can reset `activeProfileID` (the resolver's `screen.default` fallback is the net
    /// underneath either way). No-op (false) for built-ins and unknown ids.
    @discardableResult
    public func delete(id: String, activeProfileID: String) -> Bool {
        let countBefore = catalog.profiles.count
        catalog.profiles.removeAll { $0.id == id }
        guard catalog.profiles.count != countBefore else { return false }
        persist()
        return id == activeProfileID
    }

    public static func load(from defaults: UserDefaults) -> ProfileCatalog {
        guard let data = defaults.data(forKey: ProfileCatalog.defaultsKey),
              let catalog = try? JSONDecoder().decode(ProfileCatalog.self, from: data)
        else { return .empty }
        return catalog
    }

    private func persist() {
        catalog.schemaVersion = ProfileCatalog.currentSchemaVersion
        if let data = try? JSONEncoder().encode(catalog) {
            defaults.set(data, forKey: ProfileCatalog.defaultsKey)
        }
    }
}

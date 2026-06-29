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
            promptTemplate: source.promptTemplate,
            modelBinding: source.modelBinding,
            moduleOverrides: source.moduleOverrides,
            toolSpec: source.toolSpec,
            outputConfig: source.outputConfig
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

    /// THE edit choke point: mutate a user profile's editable fields through
    /// ``GroundProfile/edited(_:)`` and persist. No-op for built-ins and unknown ids (built-ins never
    /// enter the catalog, so `first(where:)` already excludes them, and `edited`/`update` refuse them
    /// again as further nets). Every setter routes through here, so invariant re-application
    /// (primary-ground re-insertion, eligibility sanitize) lives in exactly one place and no field can
    /// be wiped by a caller forgetting to thread it through.
    public func mutate(id: String, _ transform: (inout GroundProfile.Editable) -> Void) {
        guard let existing = catalog.profiles.first(where: { $0.id == id }) else { return }
        update(existing.edited(transform))
    }

    public func rename(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id: id) { $0.displayName = trimmed }
    }

    /// Stores the instruction capped at the limit (the read path fully sanitizes — see
    /// `ProfileInstruction.sanitized`); empty clears it.
    public func setInstruction(id: String, _ text: String) {
        let capped = text.isEmpty ? nil : String(text.prefix(ProfileInstruction.maxLength))
        mutate(id: id) { $0.instruction = capped }
    }

    /// Stores the prompt template capped at the limit (the read path fully sanitizes — see
    /// `ProfileTemplate.sanitized`); empty clears it.
    public func setPromptTemplate(id: String, _ text: String) {
        let capped = text.isEmpty ? nil : String(text.prefix(ProfileTemplate.maxLength))
        mutate(id: id) { $0.promptTemplate = capped }
    }

    /// Stores a profile's tool spec, forcing the HTTP transport and clearing any `command`: a
    /// `.command` tool is arbitrary local code execution the sandboxed signed app cannot run and that
    /// never travels in a shared preset, so the editor must never create or save one. An empty or
    /// whitespace url is allowed to persist (an in-progress edit) but normalizes to nil, leaving the
    /// spec ``ToolSpec/isUsable`` false so the profile degrades to no tool.
    public func setToolSpec(id: String, _ spec: ToolSpec) {
        let httpOnly = ToolSpec(
            transport: .http,
            url: spec.url,
            command: nil,
            arguments: spec.arguments,
            sendsScreenshot: spec.sendsScreenshot,
            sendsText: spec.sendsText,
            outputLabel: spec.outputLabel,
            timeoutSeconds: spec.timeoutSeconds
        )
        mutate(id: id) { $0.toolSpec = httpOnly }
    }

    /// Creates a `.tool`-primary user profile under a fresh UUID id, seeded with a default HTTP
    /// ``ToolSpec`` that has no endpoint yet (the editor fills it in). Returns nil when the catalog is
    /// at ``ProfileCatalog/maxProfiles``. Distinct from ``duplicate(_:name:)``, which copies a screen
    /// built-in: there is no `.tool` built-in to copy, so this is its own create path. Like the other
    /// mutators it persists immediately and does not change the active profile.
    @discardableResult
    public func createToolProfile(name: String) -> GroundProfile? {
        guard catalog.profiles.count < ProfileCatalog.maxProfiles else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = GroundProfile(
            id: UUID().uuidString,
            displayNameKey: "Tool",
            symbol: "wrench.and.screwdriver",
            primaryGround: .tool,
            activeGrounds: [.tool],
            isBuiltIn: false,
            displayName: trimmed.isEmpty ? nil : trimmed,
            toolSpec: ToolSpec(transport: .http, url: "", sendsScreenshot: true)
        )
        catalog.profiles.append(profile)
        persist()
        return profile
    }

    /// `nil` clears the binding (back to the global answer model).
    public func setModelBinding(id: String, _ binding: ProfileModelBinding?) {
        mutate(id: id) { $0.modelBinding = binding }
    }

    /// `nil` clears the override (inherit global). Ineligible modules no-op (see ``ModuleOverrides``).
    public func setModuleOverride(id: String, module: ModuleID, enabled: Bool?) {
        mutate(id: id) { $0.moduleOverrides.set(module, enabled) }
    }

    public func clearModuleOverrides(id: String) {
        mutate(id: id) { $0.moduleOverrides = .none }
    }

    /// Stores the profile's output config (translation languages). The edit seam normalizes an
    /// all-empty config to nil, so clearing both languages persists no config at all — the field never
    /// lingers as an empty blob. Sanitization (trim + cap + empty->nil) runs here and again on decode.
    public func setOutputConfig(id: String, _ config: ProfileOutputConfig) {
        let sanitized = config.sanitized
        mutate(id: id) { $0.outputConfig = sanitized.isEmpty ? nil : sanitized }
    }

    /// Sets a USER profile's active grounds, persisting immediately. No-op for built-ins and unknown
    /// ids (built-ins resolve through ``GroundProfile/all``, never this catalog, so `first(where:)`
    /// already excludes them — `edited`/`update` refuse them again as a second net). The passed set is
    /// sanitized by the edit seam (``GroundProfile/edited(_:)``) regardless of the caller: anything
    /// outside ``Ground/multiGroundEligible`` (camera, file, voice input, agent) is dropped, and
    /// `primaryGround` is always kept so the profile can still capture its lead ground. The fan-out at
    /// capture time applies the further `systemAudio` opt-in gate (see ``CaptureCoordinator``), so
    /// storing `.systemAudio` here never arms the live tap.
    public func setActiveGrounds(_ grounds: Set<Ground>, for id: String) {
        mutate(id: id) { $0.activeGrounds = grounds }
    }

    // MARK: - Import / export presets

    /// Portable preset bytes for the user's own profiles (built-ins are dropped by ``ProfilePreset``).
    /// Pass a subset (e.g. one profile to share) or omit to export the whole user catalog.
    public func exportPreset(ids: [String]? = nil) throws -> Data {
        let profiles: [GroundProfile]
        if let ids {
            let wanted = Set(ids)
            profiles = catalog.profiles.filter { wanted.contains($0.id) }
        } else {
            profiles = catalog.profiles
        }
        return try ProfilePreset.export(profiles)
    }

    /// Import a shareable preset, ADDING its profiles to the catalog under fresh ids (so it can never
    /// overwrite or strand an existing profile). Tolerant: hostile/malformed bytes import nothing.
    /// Returns the profiles actually added (empty when the preset was unreadable or the catalog is at
    /// capacity), so the caller can report the count or activate a freshly imported profile.
    @discardableResult
    public func importPreset(from data: Data) -> [GroundProfile] {
        let preset = (try? JSONDecoder().decode(ProfilePreset.self, from: data)) ?? ProfilePreset(profiles: [])
        let toAdd = preset.installable(into: catalog)
        guard !toAdd.isEmpty else { return [] }
        catalog.profiles.append(contentsOf: toAdd)
        persist()
        return toAdd
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

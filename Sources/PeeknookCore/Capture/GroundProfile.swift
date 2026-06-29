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
    /// User-copy literal name (typed by the user — rendered verbatim, never a catalog key).
    /// Nil for built-ins, which localize through `displayNameKey`.
    public let displayName: String?
    /// Free-text persona the profile injects into the system prompt (via `agentSystemAppendix`).
    /// Nil/empty = none. Sanitized (trim + cap) on decode; see ``ProfileInstruction``.
    public let instruction: String?
    /// Optional free-form prompt template the profile folds into the system prompt as its OWN fenced
    /// section, BEYOND the standing `instruction`. Nil/empty = none (behavior byte-identical to before).
    /// Sanitized (trim + cap) on decode and fenced when built so user text can never break the stable
    /// system-prompt contract; see ``ProfileTemplate``. NOT a mode — free text, never a curated list.
    public let promptTemplate: String?
    /// Optional answer-model override; nil = the global `answerModel`/`activeEndpoint`.
    public let modelBinding: ProfileModelBinding?
    /// Sparse per-profile module forcing; `.none` = pure global read-through.
    public let moduleOverrides: ModuleOverrides
    /// Optional local tool this profile runs to produce a VERIFIED text leg (chess engine, solver,
    /// runner). Meaningful only for a `.tool`-primary profile; nil = no tool. Sanitized + tolerant on
    /// decode (see ``ToolSpec``). Schema only in slice 1 — no provider runs it yet.
    public let toolSpec: ToolSpec?
    /// Optional per-profile output shaping (today: translation languages). Nil = no shaping (requests
    /// stay byte-identical to before). Tolerant + sanitized on decode (see ``ProfileOutputConfig``).
    /// This is DATA, never a behavior name — the first field added through the M1 edit seam.
    public let outputConfig: ProfileOutputConfig?

    public init(
        id: String,
        displayNameKey: String,
        symbol: String,
        primaryGround: Ground,
        activeGrounds: Set<Ground>,
        isBuiltIn: Bool,
        displayName: String? = nil,
        instruction: String? = nil,
        promptTemplate: String? = nil,
        modelBinding: ProfileModelBinding? = nil,
        moduleOverrides: ModuleOverrides = .none,
        toolSpec: ToolSpec? = nil,
        outputConfig: ProfileOutputConfig? = nil
    ) {
        self.id = id
        self.displayNameKey = displayNameKey
        self.symbol = symbol
        self.primaryGround = primaryGround
        self.activeGrounds = activeGrounds
        self.isBuiltIn = isBuiltIn
        self.displayName = displayName
        self.instruction = instruction
        self.promptTemplate = promptTemplate
        self.modelBinding = modelBinding
        self.moduleOverrides = moduleOverrides
        self.toolSpec = toolSpec
        self.outputConfig = outputConfig
    }

    /// Union of the required permissions of every active ground. Supplementary grounds (AX via
    /// `selectedText`) contribute nothing — see ``Ground/requiredPermissions``.
    public var requiredPermissions: Set<CapturePermission> {
        var permissions = activeGrounds.reduce(into: Set<CapturePermission>()) {
            $0.formUnion($1.requiredPermissions)
        }
        // A `.tool` ground requires no TCC of its own (it reaches a local endpoint), but when its
        // `ToolSpec` sends the screenshot as input the capture takes a screen frame, which needs Screen
        // Recording. Compose it here so readiness gates a screenshot-sending tool profile correctly.
        if primaryGround == .tool, toolSpec?.sendsScreenshot == true {
            permissions.insert(.screenRecording)
        }
        return permissions
    }
}

// MARK: - Tolerant Codable (forward-compat for the future persisted profile catalog)

extension GroundProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, displayNameKey, symbol, primaryGround, activeGrounds, isBuiltIn
        case displayName, instruction, promptTemplate, modelBinding, moduleOverrides, toolSpec
        case outputConfig
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
        // The profiles-v1 fields, each individually `try?`-shielded: a malformed field degrades
        // to its default without taking the profile (or the whole catalog) down with it.
        displayName = ((try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil)
        instruction = ProfileInstruction.sanitized(
            (try? container.decodeIfPresent(String.self, forKey: .instruction)) ?? nil
        )
        promptTemplate = ProfileTemplate.sanitized(
            (try? container.decodeIfPresent(String.self, forKey: .promptTemplate)) ?? nil
        )
        modelBinding = ((try? container.decodeIfPresent(ProfileModelBinding.self, forKey: .modelBinding)) ?? nil)
        moduleOverrides = ((try? container.decodeIfPresent(ModuleOverrides.self, forKey: .moduleOverrides)) ?? nil) ?? .none
        toolSpec = ((try? container.decodeIfPresent(ToolSpec.self, forKey: .toolSpec)) ?? nil)
        // An emptied/all-nil config never lingers: normalize it to nil so a stale `outputConfig: {}`
        // (or a blob whose only language field was malformed) carries no phantom config forward.
        let decodedOutputConfig = ((try? container.decodeIfPresent(ProfileOutputConfig.self, forKey: .outputConfig)) ?? nil)
        outputConfig = (decodedOutputConfig?.isEmpty == true) ? nil : decodedOutputConfig
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayNameKey, forKey: .displayNameKey)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(primaryGround.rawValue, forKey: .primaryGround)
        try container.encode(activeGrounds.map(\.rawValue).sorted(), forKey: .activeGrounds)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        // Conditional: a built-in (every optional field at its default) encodes exactly the six legacy keys.
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(instruction, forKey: .instruction)
        try container.encodeIfPresent(promptTemplate, forKey: .promptTemplate)
        try container.encodeIfPresent(modelBinding, forKey: .modelBinding)
        if moduleOverrides != .none {
            try container.encode(moduleOverrides, forKey: .moduleOverrides)
        }
        try container.encodeIfPresent(toolSpec, forKey: .toolSpec)
        // Conditional like the rest: a built-in (no output config) still encodes exactly the six legacy
        // keys, so the M1 freeze canary stays green; only a profile that set languages carries this key.
        try container.encodeIfPresent(outputConfig, forKey: .outputConfig)
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

    /// Camera-first profile: requires Camera TCC only — **not** Screen Recording. Defined here so
    /// every `.cameraLive`-scoped gate (command-bar modules, readiness) can key on this literal —
    /// the single profile-source rule: ⌘⇧C is event-scoped, `activeProfileID` never changes in v1,
    /// and the live-camera surface always resolves against `cameraStudy`, never `activeProfile`.
    /// No `.selectedText`: an AX text selection has no on-screen target for a camera frame, so
    /// including it would silently widen what a camera capture sends.
    static let cameraStudy = GroundProfile(
        id: "camera.study",
        displayNameKey: "Camera",
        symbol: "camera",
        primaryGround: .camera,
        activeGrounds: [.camera],
        isBuiltIn: true
    )

    /// Built-in profiles. The user's own profiles live in ``ProfileStore``/`peeknook.profiles.v1`.
    static var all: [GroundProfile] { [.screenDefault, .cameraStudy] }

    /// Resolve a profile id to its built-in, falling back to `screen.default` for an unknown id
    /// (so a stale persisted `activeProfileID` can never strand the user).
    static func builtIn(id: String) -> GroundProfile {
        all.first { $0.id == id } ?? .screenDefault
    }

    /// THE active-profile resolver: built-ins + the user catalog, unknown/deleted id →
    /// `screen.default` (the existing fallback). Both the orchestrator and the setup coordinator
    /// resolve through this one function so they can never split-brain.
    static func resolve(id: String, in userProfiles: [GroundProfile]) -> GroundProfile {
        all.first { $0.id == id }
            ?? userProfiles.first { $0.id == id }
            ?? .screenDefault
    }

    /// The editable surface of a profile: every field a user (or the future profile editor) can
    /// change, and nothing else. The identity fields (`id`, `isBuiltIn`, `displayNameKey`, `symbol`,
    /// `primaryGround`) are deliberately absent — they define the profile and never change through an
    /// edit. Mutate one via ``GroundProfile/edited(_:)``, which re-applies the profile invariants in a
    /// single place afterward, so a caller can never silently wipe a field by omission (the footgun the
    /// old explicit-every-field `with(...)` factory invited: forget `promptTemplate`, lose it).
    struct Editable: Equatable, Sendable {
        public var displayName: String?
        public var instruction: String?
        public var promptTemplate: String?
        public var modelBinding: ProfileModelBinding?
        public var moduleOverrides: ModuleOverrides
        public var toolSpec: ToolSpec?
        /// Per-profile output shaping (translation languages today). Nil = none.
        public var outputConfig: ProfileOutputConfig?
        /// The foldable capture grounds. Set this freely — ``GroundProfile/edited(_:)`` sanitizes the
        /// result to ``Ground/multiGroundEligible`` and re-inserts the always-present `primaryGround`,
        /// so a profile can never lose its lead ground nor carry a non-foldable one.
        public var activeGrounds: Set<Ground>

        public init(
            displayName: String?,
            instruction: String?,
            promptTemplate: String?,
            modelBinding: ProfileModelBinding?,
            moduleOverrides: ModuleOverrides,
            toolSpec: ToolSpec?,
            outputConfig: ProfileOutputConfig?,
            activeGrounds: Set<Ground>
        ) {
            self.displayName = displayName
            self.instruction = instruction
            self.promptTemplate = promptTemplate
            self.modelBinding = modelBinding
            self.moduleOverrides = moduleOverrides
            self.toolSpec = toolSpec
            self.outputConfig = outputConfig
            self.activeGrounds = activeGrounds
        }
    }

    /// This profile's current editable state, seeded for an ``edited(_:)`` pass.
    var editable: Editable {
        Editable(
            displayName: displayName,
            instruction: instruction,
            promptTemplate: promptTemplate,
            modelBinding: modelBinding,
            moduleOverrides: moduleOverrides,
            toolSpec: toolSpec,
            outputConfig: outputConfig,
            activeGrounds: activeGrounds
        )
    }

    /// The active-grounds invariant in ONE definition, shared by the edit seam (``edited(_:)``) and the
    /// import boundary (``ProfilePreset/installable(into:)``): grounds reduced to the foldable
    /// ``Ground/multiGroundEligible`` set with `primary` always re-inserted, so a stored profile can
    /// never lose its lead ground nor carry a non-foldable one. A single definition keeps the two write
    /// boundaries from ever drifting apart, and makes the seam's sanitize a provable no-op on data that
    /// already passed the import boundary.
    static func sanitizedActiveGrounds(_ grounds: Set<Ground>, primary: Ground) -> Set<Ground> {
        var sanitized = grounds.intersection(Ground.multiGroundEligible)
        sanitized.insert(primary)   // the primary ground is always active
        return sanitized
    }

    /// The single profile-edit seam: returns a copy with the editable fields changed by `mutate`, then
    /// re-applies the profile invariants in ONE place — the only reason this exists.
    ///
    /// - A **built-in is immutable**: it returns `self` unchanged. Its fields are part of its identity,
    ///   and ``ProfileStore`` never persists a built-in anyway, so an edit must be a no-op.
    /// - Otherwise `activeGrounds` is sanitized through ``sanitizedActiveGrounds(_:primary:)``, so the
    ///   result can never lose its lead ground nor keep a non-foldable one.
    ///
    /// This replaces the explicit-every-field `with(...)` factory: a caller mutates only what it means
    /// to, and no field can be silently dropped by forgetting to thread it through.
    func edited(_ mutate: (inout Editable) -> Void) -> GroundProfile {
        guard !isBuiltIn else { return self }
        var draft = editable
        mutate(&draft)
        return GroundProfile(
            id: id,
            displayNameKey: displayNameKey,
            symbol: symbol,
            primaryGround: primaryGround,
            activeGrounds: Self.sanitizedActiveGrounds(draft.activeGrounds, primary: primaryGround),
            isBuiltIn: isBuiltIn,
            displayName: draft.displayName,
            instruction: draft.instruction,
            promptTemplate: draft.promptTemplate,
            modelBinding: draft.modelBinding,
            moduleOverrides: draft.moduleOverrides,
            toolSpec: draft.toolSpec,
            outputConfig: draft.outputConfig.flatMap { $0.isEmpty ? nil : $0.sanitized }
        )
    }
}

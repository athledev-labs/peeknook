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
        toolSpec: ToolSpec? = nil
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
        case displayName, instruction, promptTemplate, modelBinding, moduleOverrides, toolSpec
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

    /// Copy with edited user-profile fields (identity and `isBuiltIn` are never editable). For
    /// ``ProfileStore`` and the profile editor. Every editable field is explicit so a caller can never
    /// silently drop one (e.g. wipe `promptTemplate` by forgetting it).
    ///
    /// `activeGrounds` defaults to `nil` ("keep what's there") so the existing edit paths stay
    /// unchanged. It is honored only for USER profiles — a built-in's grounds are part of its identity
    /// and never change (a built-in always keeps its own `activeGrounds`). When honored, `primaryGround`
    /// is re-inserted so a profile can never lose the ground its captures lead with; the broader
    /// eligibility sanitize lives in ``ProfileStore/setActiveGrounds(_:for:)``.
    func with(
        displayName: String?,
        instruction: String?,
        promptTemplate: String?,
        modelBinding: ProfileModelBinding?,
        moduleOverrides: ModuleOverrides,
        toolSpec: ToolSpec?,
        activeGrounds: Set<Ground>? = nil
    ) -> GroundProfile {
        let resolvedGrounds: Set<Ground>
        if let activeGrounds, !isBuiltIn {
            var grounds = activeGrounds
            grounds.insert(primaryGround)   // the primary ground is always active
            resolvedGrounds = grounds
        } else {
            resolvedGrounds = self.activeGrounds   // built-ins (and no-op edits) keep their grounds
        }
        return GroundProfile(
            id: id,
            displayNameKey: displayNameKey,
            symbol: symbol,
            primaryGround: primaryGround,
            activeGrounds: resolvedGrounds,
            isBuiltIn: isBuiltIn,
            displayName: displayName,
            instruction: instruction,
            promptTemplate: promptTemplate,
            modelBinding: modelBinding,
            moduleOverrides: moduleOverrides,
            toolSpec: toolSpec
        )
    }
}

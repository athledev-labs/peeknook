// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Command registry (Phase 1.5)
//
// A data-driven model of the notch command bars. Today three hardcoded SwiftUI surfaces render the
// idle / active-controls / result commands (`PeekIdleCommandBar`, `PeekHomeActiveControls`,
// `PeekHomeResultView.resultCommandBar`). This describes those commands as **pure, `Sendable`,
// `Codable` data** so a single `PeekCommandBar` can render them, camera v1 can add a `.cameraLive`
// group by appending descriptors (no new bar code), and a future Settings → Layout can reorder / hide
// / rebind purely additively.
//
// CONTRACTS (the guardrails that keep this scalable — do not break without a written decision):
//   • No closures. A descriptor never carries an action closure, a `() -> Bool` gate, or a live
//     binding — that would break `Sendable`/`Codable`. The orchestrator dispatch, the transient
//     visibility predicates, and the toggled-appearance state all live in the *renderer*
//     (`PeekCommandBar`) as typed switches over `action` / `visibility`, never as data.
//   • `titleKey` / `helpKey` / `CommandFace.*Key` are `Localizable.xcstrings` KEYS, never resolved
//     strings — the renderer resolves them through `Text(peek:)` against `Bundle.module`.
//   • For `.valueDropdown` kinds the *visible* pill text and icon are derived live from the bound
//     setting (depth → hare/tortoise, scope → macwindow/display); `titleKey`/`symbol` are the
//     a11y/help label and a fallback only. The dimension fully specifies the binding + menu builder.
//   • The descriptor is fully immutable. User-mutable order/visibility/rebinding land later as a
//     separate `CommandOverride` keyed by stable `id`, persisted under `peeknook.*` with
//     `decodeIfPresent ?? []` and unknown ids dropped — the same tolerant-decode discipline as
//     ``GroundProfile``. Nothing here persists in Phase 1.5; the layout is code-defined.
//   • Persistence tolerance: when a `Command*` enum value is *first written to disk* (the future
//     override), the associated-value enums (`CommandKind`, `CommandHotkeyBinding`) need a
//     hand-written non-throwing `init(from:)` (auto-synthesised `Codable` throws on an unknown raw
//     value, which `PeeknookSettings.load`'s top-level `try?` would turn into a full settings reset).
//     Auto-synthesis is fine for the in-memory / round-trip use here.

/// Which command bar a descriptor belongs to. The three shipped surfaces are mutually exclusive by
/// ``SessionPhase``; `.cameraLive` is the seam camera v1 plugs into (Shutter / Cancel) and carries no
/// descriptor until then.
public enum CommandPlacement: String, Codable, Sendable, CaseIterable {
    case idle        // PeekIdleCommandBar — phase .idle
    case active      // PeekHomeActiveControls — phases .previewing / .capturing / .inferring
    case result      // PeekHomeResultView result bar — phase .result
    case cameraLive  // RESERVED — camera v1 live-preview surface (Shutter / Cancel)
}

/// The four preflight settings a `.valueDropdown` command can bind to. Maps 1:1 onto the
/// `PeekPreflightMenuContent` builders and `PeekPreflightOptions`. `.imageReplay` is reserved — it is
/// settings-backed but not in any shipped bar yet, so `screenDefault` omits it.
public enum PreflightDimension: String, Codable, Sendable, CaseIterable {
    case model, depth, scope, imageReplay
}

/// How a command renders: a fire-once button or a value-selecting dropdown bound to a preflight
/// dimension.
public enum CommandKind: Codable, Sendable, Equatable {
    case button
    case valueDropdown(PreflightDimension)
}

/// The typed action the renderer dispatches to the orchestrator / host. Never a closure — keeps
/// descriptors `Sendable` and persistable. `.valueDropdown` commands carry no action (the dimension
/// drives their behaviour), so ``CommandDescriptor/action`` is optional.
public enum CommandAction: String, Codable, Sendable, CaseIterable {
    case capture, beginCameraCapture, shutter, cancel, confirmPreview
    case brief, resume, followUp, speak, done, newChat
    case history, export, retake, addImage
    // case planAction   ← Phase 5 sidecar (agent control)
}

/// A hotkey slot backed by a ``PeeknookSettings`` field. `.camera` is reserved and inert until camera
/// v1 adds `cameraHotkey`; the renderer resolves an unbacked slot to "no keycaps".
public enum HotkeySlot: String, Codable, Sendable { case capture, brief, camera }

/// How a command surfaces a keyboard shortcut.
public enum CommandHotkeyBinding: Codable, Sendable, Equatable {
    case none
    case settingsSlot(HotkeySlot)
    // case profileLocal(CaptureHotkey)   ← per-profile rebinding (profile editor, deferred)
}

/// Transient session-state gating the *renderer* evaluates against the live orchestrator — a typed
/// enum, never a closure. Module / permission gating stays in
/// ``CommandDescriptor/requiredModules`` / ``CommandDescriptor/requiredPermissions``; this covers
/// state that is neither a module nor a TCC permission.
public enum CommandVisibility: String, Codable, Sendable {
    case always                    // no transient gate
    case hasResumePreview          // Resume — a prior chat exists to resume
    case hasConversationHistory    // History — the thread has more than the latest answer
    case showingFullConversation   // Export — the full-thread view is open
    case previewing                // Use this — only while a capture is awaiting confirmation
}

/// An alternate appearance a command adopts while its (renderer-computed) toggle state is active.
/// Brief swaps only its symbol (outline → fill); Speak swaps title + symbol + help (Speak → Stop);
/// History swaps only its help. `nil` fields keep the base value. All `*Key`s are xcstrings keys.
public struct CommandFace: Codable, Sendable, Equatable {
    public let titleKey: String?
    public let symbol: String?
    public let helpKey: String?

    public init(titleKey: String? = nil, symbol: String? = nil, helpKey: String? = nil) {
        self.titleKey = titleKey
        self.symbol = symbol
        self.helpKey = helpKey
    }
}

/// One command in a bar. Fully immutable and code-defined in Phase 1.5.
public struct CommandDescriptor: Codable, Sendable, Equatable, Identifiable {
    /// Stable, globally-unique key (`"<placement>.<name>"`). Survives reorder/hide and is the future
    /// `CommandOverride` key. NOT the accessibility identifier — see ``accessibilityIdentifier``.
    public let id: String
    public let kind: CommandKind
    /// The orchestrator action for `.button` kinds; `nil` for `.valueDropdown` (the dimension drives it).
    public let action: CommandAction?
    /// Visible label, an xcstrings KEY. For `.valueDropdown` this is the a11y/help label; the pill text
    /// is the live bound value.
    public let titleKey: String
    public let symbol: String
    /// Appearance while the renderer-computed toggle state is active (Brief fill, Speak → Stop, …).
    public let alternateFace: CommandFace?
    public let helpKey: String?
    public let hotkey: CommandHotkeyBinding
    public let placement: CommandPlacement
    /// Rendered outside the horizontal scroll, pinned to the trailing edge (Capture, Done) so it is
    /// always reachable. At most one per placement.
    public let pinnedTrailing: Bool
    /// Base prominence. Reactive prominence (Brief / History / Follow up accent on state) is computed
    /// by the renderer from the same toggle state that drives ``alternateFace``.
    public let prominent: Bool
    public let visibility: CommandVisibility
    /// Capability gate: hidden when any required module is inactive in the active profile.
    public let requiredModules: Set<ModuleID>
    /// Capability gate: drives the *disabled* state until the active profile's permissions are granted.
    public let requiredPermissions: Set<CapturePermission>
    /// Built-in left-to-right order within a placement. A future override may supersede it.
    public let defaultOrder: Int

    public init(
        id: String,
        kind: CommandKind,
        action: CommandAction?,
        titleKey: String,
        symbol: String,
        alternateFace: CommandFace? = nil,
        helpKey: String? = nil,
        hotkey: CommandHotkeyBinding = .none,
        placement: CommandPlacement,
        pinnedTrailing: Bool = false,
        prominent: Bool = false,
        visibility: CommandVisibility = .always,
        requiredModules: Set<ModuleID> = [],
        requiredPermissions: Set<CapturePermission> = [],
        defaultOrder: Int
    ) {
        self.id = id
        self.kind = kind
        self.action = action
        self.titleKey = titleKey
        self.symbol = symbol
        self.alternateFace = alternateFace
        self.helpKey = helpKey
        self.hotkey = hotkey
        self.placement = placement
        self.pinnedTrailing = pinnedTrailing
        self.prominent = prominent
        self.visibility = visibility
        self.requiredModules = requiredModules
        self.requiredPermissions = requiredPermissions
        self.defaultOrder = defaultOrder
    }

    /// Stable XCUITest / VoiceOver identifier, derived so the on-disk `id` format stays decoupled from
    /// the test-id convention. Buttons key off `action` (so the migrated Capture / Brief / Done /
    /// New chat keep the exact `peeknook.*` identifiers existing UI tests query); dropdowns key off `id`.
    public var accessibilityIdentifier: String {
        if let action { return "peeknook.\(action.rawValue)" }
        return "peeknook.\(id)"
    }
}

/// An ordered set of commands across every placement. Code-defined in Phase 1.5.
public struct CommandLayout: Codable, Sendable, Equatable {
    public let commands: [CommandDescriptor]

    public init(commands: [CommandDescriptor]) {
        self.commands = commands
    }

    /// The commands for one bar, in render order. (A future override array would be applied here.)
    public func forPlacement(_ placement: CommandPlacement) -> [CommandDescriptor] {
        commands
            .filter { $0.placement == placement }
            .sorted { $0.defaultOrder < $1.defaultOrder }
    }
}

// MARK: - Built-in layout (the migration anchor: reproduces today's exact idle / active / result bars)

public extension CommandLayout {
    /// The shipped layout. Mirrors, command-for-command and in order, the three hardcoded surfaces at
    /// HEAD — `PeekIdleCommandBar` (Resume · Brief · Model ▾ · Depth ▾ · Scope ▾ · Capture),
    /// `PeekHomeActiveControls` (Use this · Cancel), and `PeekHomeResultView.resultCommandBar`
    /// (History · Export · Brief · Follow up · Speak · Done · New chat). This equivalence is the
    /// Phase 1.5 migration anchor; ``CommandLayoutTests`` guards it.
    static let screenDefault = CommandLayout(commands: [
        // ── Idle bar ──────────────────────────────────────────────────────────────────────────
        CommandDescriptor(
            id: "idle.resume", kind: .button, action: .resume,
            titleKey: "Resume", symbol: "arrow.uturn.backward",
            placement: .idle, visibility: .hasResumePreview, defaultOrder: 0
        ),
        CommandDescriptor(
            id: "idle.brief", kind: .button, action: .brief,
            titleKey: "Brief", symbol: "text.alignleft",
            alternateFace: CommandFace(symbol: "text.alignleft.fill"),
            hotkey: .settingsSlot(.brief),
            placement: .idle, defaultOrder: 1
        ),
        CommandDescriptor(
            id: "idle.model", kind: .valueDropdown(.model), action: nil,
            titleKey: "Answer model", symbol: "cpu",
            helpKey: "Answer model for the next capture",
            placement: .idle, defaultOrder: 2
        ),
        CommandDescriptor(
            id: "idle.depth", kind: .valueDropdown(.depth), action: nil,
            titleKey: "Answer depth", symbol: "hare",
            helpKey: "Answer depth for the next capture",
            placement: .idle, defaultOrder: 3
        ),
        CommandDescriptor(
            id: "idle.scope", kind: .valueDropdown(.scope), action: nil,
            titleKey: "Capture area", symbol: "macwindow",
            helpKey: "Capture target for the next capture",
            placement: .idle, defaultOrder: 4
        ),
        CommandDescriptor(
            id: "idle.capture", kind: .button, action: .capture,
            titleKey: "Capture", symbol: "camera.viewfinder",
            helpKey: "Instant capture from anywhere on your Mac",
            hotkey: .settingsSlot(.capture),
            placement: .idle, pinnedTrailing: true, prominent: true,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],
            defaultOrder: 5
        ),

        // ── Active controls (post-capture confirm) ────────────────────────────────────────────
        CommandDescriptor(
            id: "active.useThis", kind: .button, action: .confirmPreview,
            titleKey: "Use this", symbol: "checkmark.circle",
            placement: .active, prominent: true, visibility: .previewing, defaultOrder: 0
        ),
        CommandDescriptor(
            id: "active.cancel", kind: .button, action: .cancel,
            titleKey: "Cancel", symbol: "xmark",
            placement: .active, defaultOrder: 1
        ),

        // ── Result bar ────────────────────────────────────────────────────────────────────────
        CommandDescriptor(
            id: "result.history", kind: .button, action: .history,
            titleKey: "History", symbol: "clock.arrow.circlepath",
            alternateFace: CommandFace(helpKey: "Show only the latest answer"),
            helpKey: "View the full conversation thread",
            placement: .result, visibility: .hasConversationHistory, defaultOrder: 0
        ),
        CommandDescriptor(
            id: "result.export", kind: .button, action: .export,
            titleKey: "Export", symbol: "square.and.arrow.up",
            helpKey: "Copy the whole thread as Markdown",
            placement: .result, visibility: .showingFullConversation, defaultOrder: 1
        ),
        CommandDescriptor(
            id: "result.brief", kind: .button, action: .brief,
            titleKey: "Brief", symbol: "text.alignleft",
            alternateFace: CommandFace(symbol: "text.alignleft.fill"),
            hotkey: .settingsSlot(.brief),
            placement: .result, defaultOrder: 2
        ),
        CommandDescriptor(
            id: "result.followUp", kind: .button, action: .followUp,
            titleKey: "Follow up", symbol: "bubble.left.and.bubble.right",
            helpKey: "Ask a follow-up about this answer",
            placement: .result, defaultOrder: 3
        ),
        CommandDescriptor(
            id: "result.retake", kind: .button, action: .retake,
            titleKey: "Retake", symbol: "arrow.triangle.2.circlepath.camera",
            helpKey: "Capture a new screenshot and replace this chat",
            placement: .result,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],
            defaultOrder: 4
        ),
        CommandDescriptor(
            id: "result.addImage", kind: .button, action: .addImage,
            titleKey: "Add image", symbol: "photo.badge.plus",
            helpKey: "Capture another screenshot and add it to this chat",
            hotkey: .settingsSlot(.capture),
            placement: .result,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],
            defaultOrder: 5
        ),
        CommandDescriptor(
            id: "result.speak", kind: .button, action: .speak,
            titleKey: "Speak", symbol: "speaker.wave.2",
            alternateFace: CommandFace(titleKey: "Stop", symbol: "stop.fill", helpKey: "Stop reading the answer aloud"),
            helpKey: "Read the answer aloud",
            placement: .result, visibility: .always,
            requiredModules: [.speakAnswers], defaultOrder: 6
        ),
        CommandDescriptor(
            id: "result.done", kind: .button, action: .done,
            titleKey: "Done", symbol: "house",
            helpKey: "End this chat and return to the home screen",
            placement: .result, pinnedTrailing: true, prominent: true, defaultOrder: 7
        ),
        CommandDescriptor(
            id: "result.newChat", kind: .button, action: .newChat,
            titleKey: "New chat", symbol: "arrow.counterclockwise",
            helpKey: "Discard this thread and start fresh",
            placement: .result, defaultOrder: 8
        ),
    ])

    /// The camera profile's layout: everything from ``screenDefault`` plus the `.cameraLive`
    /// Shutter / Cancel group. A separate layout — `screenDefault` itself never gains `.cameraLive`
    /// descriptors (its empty `.cameraLive` placement is the Phase 1.5 migration anchor).
    ///
    /// Cancel deliberately carries **no** module or permission gate: a live camera surface must
    /// never render without an exit, whatever the active profile or TCC state. Shutter gates on
    /// the camera module + permission; the renderer resolves both against the `camera.study`
    /// profile literal (the single profile-source rule), not the active profile.
    static let cameraStudy = CommandLayout(commands: screenDefault.commands + [
        CommandDescriptor(
            id: "cameraLive.cancel", kind: .button, action: .cancel,
            titleKey: "Cancel", symbol: "xmark",
            placement: .cameraLive, defaultOrder: 0
        ),
        CommandDescriptor(
            id: "cameraLive.shutter", kind: .button, action: .shutter,
            titleKey: "Shutter", symbol: "circle.inset.filled",
            helpKey: "Capture a photo from the camera",
            hotkey: .settingsSlot(.camera),
            placement: .cameraLive, pinnedTrailing: true, prominent: true,
            requiredModules: [.cameraCapture], requiredPermissions: [.camera],
            defaultOrder: 1
        ),
    ])
}

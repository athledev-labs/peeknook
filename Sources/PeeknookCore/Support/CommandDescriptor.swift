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
    case capture, importFile, beginCameraCapture, shutter, cancel, confirmPreview
    case brief, resume, followUp, speak, done, newChat
    case history, export, retake, addImage
    case compositeCapture   // screen + camera asked as one question (opt-in, gated on .parallelScreen)
    case toggleLive         // arm a live session from an answered thread (opt-in, gated on .liveSession)
    case refreshLive        // capture the latest screen into the armed live chat's pending context (no infer)
    case answerLive         // answer from the already-parked live frame (no new capture)
    case updateAndAskLive   // capture the latest screen AND answer in one press
    case stopLive           // disarm the live session — the single, never-hideable exit
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
    case liveArmed                 // Stop live / Refresh / Update & ask — only while the session is armed
    case liveDisarmed              // Go live — only while the session is NOT armed
    case liveHasPendingFrame       // Answer now — armed AND a refreshed frame is waiting to be answered
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

public extension CommandDescriptor {
    /// Whether Settings → Layout may reorder or hide this command. False for the structural commands
    /// a bar must always keep reachable: pinned-trailing (Capture, Done, Shutter) and every
    /// exit/confirm (``CommandAction/cancel`` / ``CommandAction/confirmPreview``). Derived from
    /// existing descriptor fields — never an id allowlist — so it is rename-proof and auto-covers any
    /// future pinned or exit command. Enforced at BOTH the apply seam (a non-customizable command
    /// ignores any override, so a hand-edited settings blob marking `cameraLive.cancel` hidden is a
    /// no-op) and the editor (its toggle/buttons disable; the controller drops such ids before persist).
    var isCustomizable: Bool {
        if pinnedTrailing { return false }
        if action == .cancel || action == .confirmPreview { return false }
        if action == .stopLive { return false }   // the only disarm control — Layout must never hide it
        return true
    }
}

/// A user-authored delta to one command's place in a bar — reorder and/or hide — keyed by the
/// command's stable ``CommandDescriptor/id``. Persisted under `peeknook.*` as SPARSE entries (only
/// commands the user actually moved or hid).
///
/// Deliberately PRIMITIVES ONLY (`String` / `Int?` / `Bool`): it carries no `Command*`
/// associated-value enum, so its auto-synthesised `Codable` can never throw on an unknown raw value
/// and so can never trip ``PeeknookSettings``' full-reset-on-decode-throw (invariant #3). A stale id
/// (a command removed in a later release) decodes fine as a String and is simply dropped at apply
/// time — never at decode. `CommandOverrideTests` asserts the no-enum-on-disk shape so a future
/// rebind feature cannot silently re-arm that trap.
public struct CommandOverride: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// The user's explicit rank within the placement, or `nil` for a hidden-only (un-reordered)
    /// entry. Reordered commands sort ahead of un-reordered ones — see
    /// ``CommandLayout/forPlacement(_:applying:)``.
    public let order: Int?
    public let hidden: Bool

    public init(id: String, order: Int? = nil, hidden: Bool = false) {
        self.id = id
        self.order = order
        self.hidden = hidden
    }
}

/// An ordered set of commands across every placement. Code-defined in Phase 1.5.
public struct CommandLayout: Codable, Sendable, Equatable {
    public let commands: [CommandDescriptor]

    public init(commands: [CommandDescriptor]) {
        self.commands = commands
    }

    /// The commands for one bar, in render order, with the user's layout ``CommandOverride`` deltas
    /// applied. Empty overrides return the exact filter+sort the bar shipped with — the byte-identical
    /// migration anchor (``CommandLayout/screenDefault``).
    ///
    /// TWO-BUCKET merge, deliberately NOT a single shared integer axis: commands the user reordered (a
    /// customizable command carrying a non-nil ``CommandOverride/order``) emit first in that order;
    /// every other command — including any command added in a future release with no override entry —
    /// appends afterward in ``CommandDescriptor/defaultOrder``. So a newly shipped command keeps its
    /// authored slot among the un-reordered commands and can never collide with a saved user rank,
    /// vanish, or land non-deterministically. (A reorder writes dense ranks for the placement's
    /// customizable commands — see `PeekSettingsController.moveCommand` — which is collision-free here
    /// precisely because new commands fall to bucket 2.)
    ///
    /// Non-customizable commands ignore overrides entirely (never hidden, never reordered), so neither
    /// the editor nor a hand-edited settings blob can strip a bar's Capture trigger or a surface's exit.
    public func forPlacement(_ placement: CommandPlacement, applying overrides: [CommandOverride]) -> [CommandDescriptor] {
        merged(placement, applying: overrides, includeHidden: false)
    }

    /// The commands for one bar, in render order. The no-override anchor (delegates with no overrides),
    /// kept byte-identical to the shipped bars so ``CommandLayoutTests`` stays the structural floor.
    public func forPlacement(_ placement: CommandPlacement) -> [CommandDescriptor] {
        forPlacement(placement, applying: [])
    }

    /// Editor-facing ordering: the placement in the user's current order but KEEPING hidden commands
    /// (so Settings → Layout can show a hidden command's toggle to bring it back) and KEEPING
    /// non-customizable commands (rendered with disabled controls). Same two-bucket order as the bar.
    public func orderedForEditing(_ placement: CommandPlacement, applying overrides: [CommandOverride]) -> [CommandDescriptor] {
        merged(placement, applying: overrides, includeHidden: true)
    }

    private func merged(
        _ placement: CommandPlacement,
        applying overrides: [CommandOverride],
        includeHidden: Bool
    ) -> [CommandDescriptor] {
        let base = commands
            .filter { $0.placement == placement }
            .sorted { $0.defaultOrder < $1.defaultOrder }
        guard !overrides.isEmpty else { return base }

        let byID = Dictionary(overrides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Hide drops only customizable commands; a non-customizable command ignores any hidden flag.
        let survivors = includeHidden
            ? base
            : base.filter { !($0.isCustomizable && byID[$0.id]?.hidden == true) }

        // Bucket 1: user-reordered (customizable + explicit order), by that order. Bucket 2: everything
        // else, by defaultOrder. A future command with no entry is always in bucket 2 — never collides.
        var reordered: [CommandDescriptor] = []
        var rest: [CommandDescriptor] = []
        for command in survivors {
            if command.isCustomizable, byID[command.id]?.order != nil {
                reordered.append(command)
            } else {
                rest.append(command)
            }
        }
        reordered.sort { lhs, rhs in
            let lo = byID[lhs.id]?.order ?? lhs.defaultOrder
            let ro = byID[rhs.id]?.order ?? rhs.defaultOrder
            return lo != ro ? lo < ro : lhs.defaultOrder < rhs.defaultOrder
        }
        return reordered + rest
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
            id: "idle.importFile", kind: .button, action: .importFile,
            titleKey: "Import file", symbol: "doc.badge.plus",
            helpKey: "Open a PDF or image from disk to ask about",
            placement: .idle, defaultOrder: 5
        ),
        CommandDescriptor(
            id: "idle.compositeCapture", kind: .button, action: .compositeCapture,
            titleKey: "Screen + camera", symbol: "photo.on.rectangle.angled",
            helpKey: "Capture your screen and a camera photo for one question",
            placement: .idle,
            requiredModules: [.parallelScreen, .screenCapture],
            requiredPermissions: [.screenRecording, .camera],
            defaultOrder: 7
        ),
        CommandDescriptor(
            id: "idle.capture", kind: .button, action: .capture,
            titleKey: "Capture", symbol: "camera.viewfinder",
            helpKey: "Instant capture from anywhere on your Mac",
            hotkey: .settingsSlot(.capture),
            placement: .idle, pinnedTrailing: true, prominent: true,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],
            defaultOrder: 6
        ),
        // Idle Stop — only reachable when a Live session persisted across Done (`livePersistAcrossDone`),
        // so the armed thread is one-tap disarmable from the home screen. Mirrors `result.stopLive`: no
        // `requiredModules` (the sole disarm control must never be module-gated while armed) and
        // `action == .stopLive` makes it non-customizable for free (Layout can never hide it).
        CommandDescriptor(
            id: "idle.stopLive", kind: .button, action: .stopLive,
            titleKey: "Stop", symbol: "stop.circle",
            helpKey: "Stop the live session",
            placement: .idle, visibility: .liveArmed, defaultOrder: 8
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
            titleKey: "Copy thread", symbol: "doc.on.doc",
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
            id: "result.compositeCapture", kind: .button, action: .compositeCapture,
            titleKey: "Screen + camera", symbol: "photo.on.rectangle.angled",
            helpKey: "Add a screen and camera photo to this chat as one question",
            placement: .result,
            requiredModules: [.parallelScreen, .screenCapture],
            requiredPermissions: [.screenRecording, .camera],
            defaultOrder: 9
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
            id: "result.toggleLive", kind: .button, action: .toggleLive,
            titleKey: "Go live", symbol: "dot.radiowaves.left.and.right",
            helpKey: "Keep this chat live so it stays in context across captures",
            placement: .result, visibility: .liveDisarmed,
            requiredModules: [.liveSession],
            defaultOrder: 10
        ),
        CommandDescriptor(
            id: "result.refreshLive", kind: .button, action: .refreshLive,
            titleKey: "Refresh", symbol: "arrow.clockwise",
            helpKey: "Capture the latest screen into this live chat",
            placement: .result, visibility: .liveArmed,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],
            defaultOrder: 11
        ),
        CommandDescriptor(
            id: "result.answerNow", kind: .button, action: .answerLive,
            titleKey: "Answer now", symbol: "arrow.up.message",
            helpKey: "Answer from the latest screen Peek already grabbed",
            placement: .result, visibility: .liveHasPendingFrame,
            requiredModules: [.liveSession],   // no permission gate: it answers a frame already captured
            defaultOrder: 12
        ),
        CommandDescriptor(
            id: "result.updateAndAsk", kind: .button, action: .updateAndAskLive,
            titleKey: "Update & ask", symbol: "arrow.clockwise.circle",
            helpKey: "Capture the latest screen and answer in one step",
            placement: .result, visibility: .liveArmed,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],   // it re-captures
            defaultOrder: 13
        ),
        CommandDescriptor(
            id: "result.stopLive", kind: .button, action: .stopLive,
            titleKey: "Stop", symbol: "stop.circle",
            helpKey: "Stop the live session",
            placement: .result, visibility: .liveArmed, defaultOrder: 14
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

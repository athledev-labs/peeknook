// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A plain snapshot of the session / setup state a command bar reacts to — the inputs that decide
/// which commands show, which are disabled, and which adopt their toggled appearance.
///
/// This is the seam that makes the bar's reactive behaviour **unit-testable without SwiftUI**: the
/// view layer builds a `CommandBarContext` from the live `SessionOrchestrator` / `SetupCoordinator`,
/// and the pure resolution below (used by both the renderer and the tests) decides the rest. No
/// orchestrator reference, no closure, no `@MainActor` — keeping the decision logic out of the view
/// is what closes the render-fidelity (H1) gap at the data layer.
public struct CommandBarContext: Sendable, Equatable {
    /// A capture is awaiting confirmation (`SessionPhase.previewing`). Drives the "Use this" command.
    public var isPreviewing: Bool
    /// `SetupCoordinator` readiness for the active profile. A command with required permissions is
    /// *disabled* (not hidden) until this is true — mirrors today's `Capture.disabled(!setup.isReady)`.
    public var isReady: Bool
    public var hasResumePreview: Bool
    public var hasConversationHistory: Bool
    public var showingFullConversation: Bool
    public var isSpeaking: Bool
    /// The session brief has content — drives Brief's filled symbol (independent of the composer).
    public var briefHasContent: Bool
    /// The brief composer is open — together with `briefHasContent` drives Brief's prominence.
    public var briefComposerVisible: Bool
    public var followUpComposerVisible: Bool
    /// Context meter at critical fill — disables Add image on the result bar.
    public var isContextBlocked: Bool
    /// Modules currently enabled in the active profile (`Module.isEnabled`). A command whose
    /// `requiredModules` are not all present is hidden (Speak when speak-answers is off, camera
    /// commands in a screen profile, …).
    public var enabledModules: Set<ModuleID>

    public init(
        isPreviewing: Bool = false,
        isReady: Bool = true,
        hasResumePreview: Bool = false,
        hasConversationHistory: Bool = false,
        showingFullConversation: Bool = false,
        isSpeaking: Bool = false,
        briefHasContent: Bool = false,
        briefComposerVisible: Bool = false,
        followUpComposerVisible: Bool = false,
        isContextBlocked: Bool = false,
        enabledModules: Set<ModuleID> = []
    ) {
        self.isPreviewing = isPreviewing
        self.isReady = isReady
        self.hasResumePreview = hasResumePreview
        self.hasConversationHistory = hasConversationHistory
        self.showingFullConversation = showingFullConversation
        self.isSpeaking = isSpeaking
        self.briefHasContent = briefHasContent
        self.briefComposerVisible = briefComposerVisible
        self.followUpComposerVisible = followUpComposerVisible
        self.isContextBlocked = isContextBlocked
        self.enabledModules = enabledModules
    }
}

// MARK: - Pure resolution (shared by PeekCommandBar and the tests)

public extension CommandDescriptor {
    /// Whether the command is rendered at all in this context. Combines the capability gate
    /// (`requiredModules` must all be enabled) with the transient ``CommandVisibility`` gate.
    func isVisible(in context: CommandBarContext) -> Bool {
        guard requiredModules.isSubset(of: context.enabledModules) else { return false }
        switch visibility {
        case .always:                  return true
        case .hasResumePreview:        return context.hasResumePreview
        case .hasConversationHistory:  return context.hasConversationHistory
        case .showingFullConversation: return context.showingFullConversation
        case .previewing:              return context.isPreviewing
        }
    }

    /// A visible-but-disabled command (e.g. Capture before Screen Recording is granted). Permission
    /// gates disable; module/visibility gates hide.
    func isDisabled(in context: CommandBarContext) -> Bool {
        if !requiredPermissions.isEmpty && !context.isReady { return true }
        if action == .addImage && context.isContextBlocked { return true }
        return false
    }

    /// Whether the command is in its toggled (alternate-appearance) state — Brief filled when the
    /// brief has content, Speak showing "Stop" while speaking, History showing the collapse affordance.
    func isToggledOn(in context: CommandBarContext) -> Bool {
        switch action {
        case .brief:   return context.briefHasContent
        case .speak:   return context.isSpeaking
        case .history: return context.showingFullConversation
        default:       return false
        }
    }

    func resolvedTitleKey(in context: CommandBarContext) -> String {
        isToggledOn(in: context) ? (alternateFace?.titleKey ?? titleKey) : titleKey
    }

    func resolvedSymbol(in context: CommandBarContext) -> String {
        isToggledOn(in: context) ? (alternateFace?.symbol ?? symbol) : symbol
    }

    func resolvedHelpKey(in context: CommandBarContext) -> String? {
        isToggledOn(in: context) ? (alternateFace?.helpKey ?? helpKey) : helpKey
    }

    /// Base prominence, plus the per-command reactive bump (Brief while composing or briefed, History
    /// while expanded, Follow up while composing) — Speak swaps its face but never accents.
    func isProminent(in context: CommandBarContext) -> Bool {
        if prominent { return true }
        switch action {
        case .brief:    return context.briefComposerVisible || context.briefHasContent
        case .history:  return context.showingFullConversation
        case .followUp: return context.followUpComposerVisible
        default:        return false
        }
    }
}

public extension CommandLayout {
    /// The commands to render for a placement: ordered, then filtered to those visible in this context.
    func visibleCommands(_ placement: CommandPlacement, in context: CommandBarContext) -> [CommandDescriptor] {
        forPlacement(placement).filter { $0.isVisible(in: context) }
    }
}

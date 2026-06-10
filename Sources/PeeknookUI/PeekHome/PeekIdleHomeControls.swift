// SPDX-License-Identifier: Apache-2.0

import AppKit
import PeeknookDesign
import PeeknookCore
import SwiftUI

// MARK: - Idle home: greeting only. Thread actions live in the command bar.

struct PeekIdleHomeContent: View {
    @Environment(\.nookResolvedTheme) private var theme
    var settings: PeeknookSettings

    var body: some View {
        if settings.showGreeting {
            Text(PeekPersonalGreeting.headline(settings: settings))
                .font(.system(size: 15, weight: .light))
                .tracking(0.2)
                .foregroundStyle(theme.primaryLabel.opacity(0.92))
        }
    }
}

enum PeekPersonalGreeting {
    static func headline(settings: PeeknookSettings) -> String {
        let name = resolvedName(settings: settings)
        guard !name.isEmpty else { return timeWord }
        return "\(timeWord), \(name)"
    }

    private static func resolvedName(settings: PeeknookSettings) -> String {
        let custom = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard custom.isEmpty else { return custom }
        return systemFirstName
    }

    private static var systemFirstName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "" }
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    private static var timeWord: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Morning"
        case 12..<17: return "Afternoon"
        case 17..<22: return "Evening"
        default: return "Hey"
        }
    }
}

// MARK: - Session brief (idle + result)

struct PeekSessionBriefStrip: View {
    var orchestrator: SessionOrchestrator
    @Binding var isComposerVisible: Bool
    @Binding var draft: String
    var focusField: FocusState<Bool>.Binding

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        if isComposerVisible {
            briefComposer
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    static func buttonHelp(for orchestrator: SessionOrchestrator) -> String {
        let base = "Tell Peeknook what you're about to study"
        let brief = orchestrator.sessionBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return base }
        return "\(base). Current brief: \(brief)"
    }

    private var briefComposer: some View {
        HStack(spacing: 8) {
            TextField("Brief this session…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focusField)
                .onSubmit(saveBrief)
                .accessibilityLabel(Text(peek: "Session brief"))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.tertiaryLabel.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            if orchestrator.settings.voiceInputEnabled {
                PeekVoiceInputButton(orchestrator: orchestrator) { transcript in
                    draft = transcript
                    saveBrief()
                }
            }
            Button(action: saveBrief) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? theme.tertiaryLabel
                        : theme.accent)
            }
            .buttonStyle(.plain)
            .peekAction(label: "Save brief")
        }
        .onChange(of: orchestrator.voicePartialTranscript) { _, partial in
            if orchestrator.isListeningForVoice, !partial.isEmpty {
                draft = partial
            }
        }
    }

    func saveBrief() {
        orchestrator.setSessionBrief(draft)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isComposerVisible = false
        }
        focusField.wrappedValue = false
    }

    func toggleComposer() {
        Self.toggleComposer(
            orchestrator: orchestrator,
            isComposerVisible: $isComposerVisible,
            draft: $draft,
            focusField: focusField
        )
    }

    static func toggleComposer(
        orchestrator: SessionOrchestrator,
        isComposerVisible: Binding<Bool>,
        draft: Binding<String>,
        focusField: FocusState<Bool>.Binding
    ) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isComposerVisible.wrappedValue.toggle()
        }
        if isComposerVisible.wrappedValue {
            draft.wrappedValue = orchestrator.sessionBrief
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusField.wrappedValue = true
            }
        } else {
            focusField.wrappedValue = false
        }
    }

    static func openComposer(
        orchestrator: SessionOrchestrator,
        isComposerVisible: Binding<Bool>,
        draft: Binding<String>,
        focusField: FocusState<Bool>.Binding
    ) {
        draft.wrappedValue = orchestrator.sessionBrief
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isComposerVisible.wrappedValue = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusField.wrappedValue = true
        }
    }
}

// MARK: - Idle command bar: Resume · Brief · preflight · Capture

struct PeekIdleCommandBar: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var settings: PeekSettingsController
    var modelCatalog: ModelCatalogService
    @Binding var pendingDownload: InferenceModelOption?
    @Binding var isBriefComposerVisible: Bool
    @Binding var briefDraft: String
    var focusBriefField: FocusState<Bool>.Binding
    var onBrowseModels: () -> Void
    var onCapture: () -> Void
    var onResume: () -> Void

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBriefComposerVisible {
                PeekSessionBriefStrip(
                    orchestrator: orchestrator,
                    isComposerVisible: $isBriefComposerVisible,
                    draft: $briefDraft,
                    focusField: focusBriefField
                )
            }
            PeekCommandBar(
                placement: .idle,
                context: commandContext,
                spacing: 8,
                resolveHotkey: hotkey(for:),
                dynamicHelp: { $0 == .brief ? PeekSessionBriefStrip.buttonHelp(for: orchestrator) : nil },
                dispatch: dispatch(_:),
                special: special(for:)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isBriefComposerVisible)
    }

    /// The reactive inputs the idle bar gates on, snapshotted for the pure resolver.
    private var commandContext: CommandBarContext {
        let profile = orchestrator.settings.activeProfile
        return CommandBarContext(
            isReady: setup.isReady,
            hasResumePreview: IdleResumePreview.from(orchestrator) != nil,
            hasConversationHistory: orchestrator.hasConversationHistory,
            isSpeaking: orchestrator.isSpeakingLastAnswer,
            briefHasContent: !orchestrator.sessionBrief.isEmpty,
            briefComposerVisible: isBriefComposerVisible,
            enabledModules: Set(ModuleID.allCases.filter {
                Module.isEnabled($0, in: orchestrator.settings, profile: profile)
            })
        )
    }

    private func hotkey(for slot: HotkeySlot) -> CaptureHotkey? {
        switch slot {
        case .capture: return orchestrator.settings.captureHotkey
        case .brief:   return orchestrator.settings.briefHotkey
        case .camera:  return orchestrator.settings.cameraHotkey
        }
    }

    private func dispatch(_ action: CommandAction) {
        switch action {
        case .capture: onCapture()
        case .resume:  onResume()
        case .brief:
            PeekSessionBriefStrip.toggleComposer(
                orchestrator: orchestrator,
                isComposerVisible: $isBriefComposerVisible,
                draft: $briefDraft,
                focusField: focusBriefField
            )
        default: break
        }
    }

    /// Bespoke cells the generic renderer delegates back to the host: the preflight dropdowns bound to
    /// settings, and the Resume preview button. Plain buttons return nil and render generically.
    private func special(for command: CommandDescriptor) -> AnyView? {
        switch command.kind {
        case .valueDropdown(let dimension):
            switch dimension {
            case .model:       return AnyView(modelMenu)
            case .depth:       return AnyView(depthMenu)
            case .scope:       return AnyView(scopeMenu)
            case .imageReplay: return nil
            }
        case .button:
            if command.action == .resume, let preview = IdleResumePreview.from(orchestrator) {
                return AnyView(PeekResumeButton(preview: preview, onResume: onResume))
            }
            return nil
        }
    }

    private var modelMenu: some View {
        ValueDropdownPill(
            symbol: "cpu",
            title: TextModelCatalog.displayName(for: orchestrator.settings.textModel, custom: settings.customModels),
            help: "Vision model for the next capture"
        ) { close in
            PeekPreflightMenuContent.visionModelHomeMenu(
                models: settings.availableModels,
                isInstalled: { setup.isModelInstalled($0) },
                isSelected: { modelCatalog.matchesModel(installedNames: [orchestrator.settings.textModel], wanted: $0.tag) },
                onSelect: selectModel,
                onBrowseModels: onBrowseModels,
                close: close
            )
        }
    }

    private var depthMenu: some View {
        let depth = AnswerDepth(quickMode: orchestrator.settings.quickMode)
        return ValueDropdownPill(
            symbol: depth == .quick ? "hare" : "tortoise",
            title: depth.barLabel,
            help: "Answer depth for the next capture"
        ) { close in
            PeekPreflightMenuContent.answerDepthHomeMenu(
                current: depth,
                onSelect: { settings.setQuickMode($0) },
                close: close
            )
        }
    }

    private var scopeMenu: some View {
        let scope = orchestrator.settings.captureScope
        return ValueDropdownPill(
            symbol: scope == .window ? "macwindow" : "display",
            title: scope.barLabel,
            help: "Capture target for the next capture"
        ) { close in
            PeekPreflightMenuContent.captureScopeHomeMenu(
                current: scope,
                onSelect: { settings.setCaptureScope($0) },
                close: close
            )
        }
    }

    private func selectModel(_ option: InferenceModelOption) {
        switch settings.pickModel(option) {
        case .selected:
            break
        case .needsDownload(let pending):
            pendingDownload = pending
        }
    }
}

/// Resume control, preview on hover via popover so the main panel never resizes (in-flow
/// expansion fights OpenNook's hover dismiss and causes a stutter loop).
private struct PeekResumeButton: View {
    @Environment(\.nookResolvedTheme) private var theme
    let preview: IdleResumePreview.Content
    let onResume: () -> Void

    @State private var isButtonHovered = false
    @State private var isPreviewHovered = false
    @State private var showsPreview = false
    @State private var hideTask: Task<Void, Never>?

    private var isPreviewVisible: Bool {
        isButtonHovered || isPreviewHovered
    }

    var body: some View {
        NookToolbarButton(
            title: "Resume",
            symbol: "arrow.uturn.backward",
            help: "\(preview.source). \(preview.answer)",
            onHoverChange: { hovering in
                isButtonHovered = hovering
                syncPreviewVisibility()
            },
            action: onResume
        )
        .popover(isPresented: $showsPreview, arrowEdge: .top) {
            previewBody
                .onHover { isPreviewHovered = $0; syncPreviewVisibility() }
        }
        .nookKeepsExpanded(while: $showsPreview)
        .onDisappear { hideTask?.cancel() }
    }

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preview.source)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(preview.answer)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.primaryLabel.opacity(0.92))
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 340, alignment: .leading)
    }

    private func syncPreviewVisibility() {
        hideTask?.cancel()
        if isPreviewVisible {
            showsPreview = true
        } else {
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, !isPreviewVisible else { return }
                showsPreview = false
            }
        }
    }
}

enum IdleResumePreview {
    struct Content: Equatable {
        var source: String
        var answer: String
    }

    @MainActor
    static func from(_ orchestrator: SessionOrchestrator) -> Content? {
        guard orchestrator.hasConversation else { return nil }
        guard let answer = orchestrator.conversation.last(where: \.isAssistant),
              case .assistant(let text) = answer.kind else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let source = orchestrator.latestAnswerCapture.map { capture in
            capture.ground == .camera
                ? PeekLocalized("Camera")
                : capture.targetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Content(
            source: source.flatMap { $0.isEmpty ? nil : $0 } ?? "Last chat",
            answer: trimmed
        )
    }
}

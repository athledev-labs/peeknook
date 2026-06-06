// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

public struct PeekHomeView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    public var settings: PeekSettingsController
    public var onOpenSetup: () -> Void
    @Environment(\.nookResolvedTheme) private var theme
    @EnvironmentObject private var appState: AppState
    @State private var followUpText = ""
    @State private var showsFullConversation = false
    @State private var showsNewChatConfirmation = false
    @State private var showsArchive = false
    @State private var hasArchivedChats = false
    @State private var pendingDownload: InferenceModelOption?
    @FocusState private var isFollowUpFieldFocused: Bool

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        settings: PeekSettingsController,
        onOpenSetup: @escaping () -> Void = {}
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.settings = settings
        self.onOpenSetup = onOpenSetup
    }

    public var body: some View {
        Group {
            if showsArchive, case .idle = orchestrator.phase {
                PeekConversationArchiveView(
                    orchestrator: orchestrator,
                    onOpen: openArchivedThread,
                    onClose: closeArchive
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                homeColumn
            }
        }
        .peekModelDownloadConfirmation(pending: $pendingDownload) { option in
            settings.beginModelDownload(option)
        }
        .onChange(of: orchestrator.phase) { _, newPhase in
            followUpText = ""
            refreshArchiveAvailability()
            if case .result = newPhase { return }
            setHistoryVisible(false)
        }
        .onChange(of: appState.moduleBreadcrumb) { _, breadcrumb in
            if breadcrumb == nil {
                if showsFullConversation { showsFullConversation = false }
                if showsArchive { showsArchive = false }
            }
        }
        .onDisappear {
            if appState.moduleBreadcrumb == Self.historyBreadcrumb
                || appState.moduleBreadcrumb == Self.archiveBreadcrumb {
                appState.moduleBreadcrumb = nil
            }
        }
        .task {
            refreshArchiveAvailability()
        }
        .task(id: setup.isReady) {
            if setup.isReady {
                await setup.refresh()
                orchestrator.prewarm()
            }
        }
        .confirmationDialog(
            "Start a new chat?",
            isPresented: $showsNewChatConfirmation,
            titleVisibility: .visible
        ) {
            Button("New chat", role: .destructive) {
                orchestrator.startNewChat()
                setHistoryVisible(false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the current conversation. You can't undo it.")
        }
    }

    private static let historyBreadcrumb = "History"
    private static let archiveBreadcrumb = "Past chats"

    private var homeColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .idle = orchestrator.phase {
                PeekIdleHomeContent(orchestrator: orchestrator, onResume: resumeChat)
            }
            if !setup.isReady {
                setupBanner
            } else if case .idle = orchestrator.phase {
                readyChip
            }
            if PracticeMode.shipped.count > 1 {
                modePicker
            }
            mainColumn
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var mainColumn: some View {
        if case .result = orchestrator.phase {
            PeekHomeResultView(
                orchestrator: orchestrator,
                setup: setup,
                showsFullConversation: $showsFullConversation,
                followUpText: $followUpText,
                focusFollowUpField: $isFollowUpFieldFocused,
                onToggleHistory: { setHistoryVisible(!showsFullConversation) },
                onFinishChat: finishChat,
                onRequestNewChat: requestNewChat
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PeekHomePhaseContent(
                    orchestrator: orchestrator,
                    showsFullConversation: showsFullConversation,
                    canRetry: setup.isReady,
                    onRecover: handleRecovery
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if case .idle = orchestrator.phase {
                    PeekIdleCommandBar(
                        orchestrator: orchestrator,
                        setup: setup,
                        settings: settings,
                        pendingDownload: $pendingDownload,
                        onCapture: { orchestrator.beginCapture() },
                        onResume: idleResumeAction,
                        onShowArchive: idleArchiveAction
                    )
                } else {
                    PeekHomeActiveControls(
                        orchestrator: orchestrator,
                        setup: setup,
                        onConfirmPreview: { orchestrator.confirmPreview() },
                        onCancel: { orchestrator.cancel() }
                    )
                }
            }
        }
    }

    private var setupBanner: some View {
        Button(action: onOpenSetup) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange.opacity(0.9))
                Text("\(setupStatusDetail) —")
                    .foregroundStyle(theme.tertiaryLabel)
                Text("Get ready")
                    .foregroundStyle(.orange)
                    .underline()
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.75))
            }
            .font(.system(size: 10, weight: .regular))
        }
        .buttonStyle(.plain)
        .help("Open setup to finish before capturing")
        .accessibilityLabel("\(setupStatusDetail). Open setup to finish before capturing.")
    }

    /// The most pressing missing prerequisite, surfaced inline so the user knows *what's* incomplete
    /// without drilling into Get ready.
    private var setupStatusDetail: String {
        if case .failed = setup.ollamaStep { return "Ollama offline" }
        if setup.modelStep != .complete { return "Model not installed" }
        if case .failed = setup.captureStep { return "Screen Recording off" }
        return "Setup incomplete"
    }

    /// Calm confirmation that capture is ready, with the active model — no drill-in required.
    private var readyChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.green.opacity(0.85))
            Text("Ready")
                .foregroundStyle(theme.secondaryLabel)
            Text("·")
                .foregroundStyle(theme.quaternaryLabel)
            Text(TextModelCatalog.displayName(for: orchestrator.settings.textModel))
                .foregroundStyle(theme.tertiaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10, weight: .regular))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ready to capture with \(TextModelCatalog.displayName(for: orchestrator.settings.textModel))")
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(PracticeMode.shipped) { mode in
                Button {
                    settings.setMode(mode)
                } label: {
                    Text(mode.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            orchestrator.settings.mode == mode
                                ? theme.primaryLabel.opacity(0.14)
                                : theme.tertiaryLabel.opacity(0.08),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var idleResumeAction: (() -> Void)? {
        guard orchestrator.hasConversation else { return nil }
        return { orchestrator.resumeChat() }
    }

    private var idleArchiveAction: (() -> Void)? {
        guard hasArchivedChats else { return nil }
        return openArchive
    }

    private func finishChat() {
        orchestrator.finishChat()
        setHistoryVisible(false)
    }

    private func resumeChat() {
        orchestrator.resumeChat()
    }

    private func handleRecovery(_ action: RecoveryAction) {
        switch action {
        case .tryAgain:
            orchestrator.retryAfterFailure()
        case .openSetup, .switchModel:
            // Setup hosts the model picker and the full readiness checklist.
            onOpenSetup()
        case .checkOllama:
            SetupCoordinator.openOllamaApp()
        case .downloadModel(let tag):
            let option = TextModelCatalog.option(for: tag)
                ?? InferenceModelOption(
                    tag: tag,
                    displayName: TextModelCatalog.displayName(for: tag),
                    provider: "Ollama"
                )
            settings.beginModelDownload(option)
            // Surface pull progress where it lives.
            onOpenSetup()
        case .openScreenRecordingSettings:
            CapturePermissionStatus.requestScreenRecording()
        case .openAccessibilitySettings:
            CapturePermissionStatus.requestAccessibility()
        }
    }

    private func requestNewChat() {
        if orchestrator.hasConversationHistory {
            showsNewChatConfirmation = true
        } else {
            orchestrator.startNewChat()
            setHistoryVisible(false)
        }
    }

    private func setHistoryVisible(_ visible: Bool) {
        withAnimation(.easeOut(duration: 0.2)) {
            showsFullConversation = visible
            appState.moduleBreadcrumb = visible ? Self.historyBreadcrumb : nil
        }
    }

    private func refreshArchiveAvailability() {
        hasArchivedChats = !orchestrator.availableThreads().isEmpty
    }

    private func openArchive() {
        withAnimation(.easeOut(duration: 0.2)) {
            showsArchive = true
            appState.moduleBreadcrumb = Self.archiveBreadcrumb
        }
    }

    private func closeArchive() {
        withAnimation(.easeOut(duration: 0.2)) {
            showsArchive = false
            appState.moduleBreadcrumb = nil
        }
    }

    private func openArchivedThread(_ summary: ConversationSummary) {
        orchestrator.openThread(id: summary.id)
        showsArchive = false
        appState.moduleBreadcrumb = nil
    }
}

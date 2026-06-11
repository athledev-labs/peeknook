// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

public struct PeekHomeView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    public var settings: PeekSettingsController
    public var modelCatalog: ModelCatalogService
    public var onOpenSetup: () -> Void
    @Environment(\.nookResolvedTheme) private var theme
    @Environment(\.nookContentInsets) private var contentInsets
    @EnvironmentObject private var appState: AppState
    @State private var followUpText = ""
    @State private var isFollowUpComposerVisible = false
    @State private var showsFullConversation = false
    @State private var showsNewChatConfirmation = false
    @State private var showsArchive = false
    @State private var showsStats = false
    @State private var showsModelLibrary = false
    @State private var pendingDownload: InferenceModelOption?
    @State private var isBriefComposerVisible = false
    @State private var briefDraft = ""
    /// Transient pin that bridges a panel resize when entering a History drill-in, then releases so
    /// normal hover-to-dismiss resumes (no forced Close).
    @State private var keepOpenGrace = false
    @State private var keepOpenGraceTask: Task<Void, Never>?
    /// Auto-clears a transient ``SessionNotice`` banner a few seconds after it appears.
    @State private var noticeDismissTask: Task<Void, Never>?
    @FocusState private var isFollowUpFieldFocused: Bool
    @FocusState private var isBriefFieldFocused: Bool

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        settings: PeekSettingsController,
        modelCatalog: ModelCatalogService,
        onOpenSetup: @escaping () -> Void = {}
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.settings = settings
        self.modelCatalog = modelCatalog
        self.onOpenSetup = onOpenSetup
    }

    public var body: some View {
        Group {
            if showsStats {
                PeekHomeLayout.contentColumn(
                    PeekStatsView(orchestrator: orchestrator, onClose: closeStats),
                    insets: contentInsets
                )
            } else if showsModelLibrary {
                PeekHomeLayout.contentColumn(
                    PeekModelLibraryView(
                        orchestrator: orchestrator,
                        setup: setup,
                        settings: settings,
                        modelCatalog: modelCatalog,
                        pendingDownload: $pendingDownload,
                        onDismiss: closeModelLibrary
                    ),
                    insets: contentInsets
                )
            } else if showsArchive, case .idle = orchestrator.phase {
                PeekHomeLayout.contentColumn(
                    PeekConversationArchiveView(
                        orchestrator: orchestrator,
                        onOpen: openArchivedThread,
                        onClose: closeArchive
                    ),
                    insets: contentInsets,
                    top: 8
                )
            } else {
                homeColumn
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .peekModelDownloadConfirmation(pending: $pendingDownload) { option in
            settings.beginModelDownload(option)
        }
        // Bridge the panel resize when entering a History drill-in (the archive list or the full
        // thread can shrink the panel, dropping the cursor outside its new bounds and auto-dismissing
        // the surface). This is a short grace pin, not a hold-open, once it expires, normal
        // hover-to-dismiss resumes so you don't have to press Close.
        .nookKeepsExpanded(while: $keepOpenGrace)
        .onChange(of: showsArchive) { _, shown in if shown { armKeepOpenGrace() } }
        .onChange(of: showsStats) { _, shown in if shown { armKeepOpenGrace() } }
        .onChange(of: showsModelLibrary) { _, shown in if shown { armKeepOpenGrace() } }
        .onChange(of: showsFullConversation) { _, shown in if shown { armKeepOpenGrace() } }
        .onChange(of: orchestrator.noticeToken) { _, _ in armNoticeAutoDismiss() }
        .onDisappear {
            keepOpenGraceTask?.cancel()
            noticeDismissTask?.cancel()
        }
        .onChange(of: orchestrator.phase) { _, newPhase in
            isFollowUpComposerVisible = false
            followUpText = ""
            if case .result = newPhase { return }
            setHistoryVisible(false)
        }
        .onChange(of: orchestrator.briefComposerFocusToken) { _, _ in
            switch orchestrator.phase {
            case .idle, .result:
                break
            default:
                return
            }
            PeekSessionBriefStrip.openComposer(
                orchestrator: orchestrator,
                isComposerVisible: $isBriefComposerVisible,
                draft: $briefDraft,
                focusField: $isBriefFieldFocused
            )
        }
        .onChange(of: appState.moduleBreadcrumb, initial: true) { _, breadcrumb in
            // Breadcrumb lives in AppState (survives compact/re-expand); drill-in flags are
            // local @State (reset when the home surface remounts). Sync on every change
            // *and* on first appear so Settings → Manage models and post-collapse restore
            // don't leave "Model Library" in the chrome over the idle home body.
            withAnimation(.easeOut(duration: 0.2)) {
                applyModuleBreadcrumb(breadcrumb)
            }
        }
        .onDisappear {
            if appState.moduleBreadcrumb == Self.archiveBreadcrumb
                || appState.moduleBreadcrumb == Self.statsBreadcrumb
                || appState.moduleBreadcrumb == Self.modelLibraryBreadcrumb {
                appState.moduleBreadcrumb = nil
            }
        }
        // Permission rows + capture-step copy are panel UI — the surface stays mounted (0×0) while the
        // notch is collapsed, so gate these polls on visibility instead of letting them run forever.
        .task(id: appState.isNookVisible) {
            guard appState.isNookVisible else { return }
            while !Task.isCancelled {
                setup.refreshCapturePermission()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // Readiness (the visible badge/CTA) and model warm-up both only matter while the panel is on
        // screen, so pause them when the notch is collapsed. Ollama's keep_alive keeps the model
        // resident for ~10 min after the last warm-up, so a ⌘⇧P capture shortly after collapsing is
        // still warm; a longer idle lets the model unload (freeing its RAM) rather than re-warming for
        // a panel nobody is looking at. Re-expanding refreshes and re-warms immediately.
        .task(id: appState.isNookVisible) {
            guard appState.isNookVisible else { return }
            while !Task.isCancelled {
                await setup.refresh()
                if setup.isReady {
                    orchestrator.prewarm()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
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

    private static let historyBreadcrumb = PeekHomeBreadcrumb.history
    private static let archiveBreadcrumb = PeekHomeBreadcrumb.pastChats
    private static let statsBreadcrumb = PeekHomeBreadcrumb.stats
    private static let modelLibraryBreadcrumb = PeekHomeBreadcrumb.modelLibrary

    /// Maps the shared chrome breadcrumb onto local drill-in state. Keep in sync with
    /// ``PeekHomeBreadcrumb`` and ``PeekModelLibraryNavigation``.
    private func applyModuleBreadcrumb(_ breadcrumb: String?) {
        switch breadcrumb {
        case Self.statsBreadcrumb:
            if allowsGlobalDrillIn {
                showsStats = true
                showsModelLibrary = false
                showsArchive = false
            } else {
                showsStats = false
                showsModelLibrary = false
                showsArchive = false
            }
        case Self.modelLibraryBreadcrumb:
            if allowsGlobalDrillIn {
                showsModelLibrary = true
                showsStats = false
                showsArchive = false
            } else {
                showsModelLibrary = false
                showsStats = false
                showsArchive = false
            }
        case Self.historyBreadcrumb:
            showsFullConversation = true
        case Self.archiveBreadcrumb:
            if case .idle = orchestrator.phase {
                showsArchive = true
                showsStats = false
                showsModelLibrary = false
            } else {
                showsArchive = false
                showsStats = false
                showsModelLibrary = false
            }
        case nil:
            showsStats = false
            showsModelLibrary = false
            showsArchive = false
            if showsFullConversation { showsFullConversation = false }
        default:
            break
        }
    }

    /// Stats and Model Library stay available on idle, result, and failed; block during capture flow
    /// and while the live camera is open (drilling in would hide a running camera surface).
    private var allowsGlobalDrillIn: Bool {
        switch orchestrator.phase {
        case .capturing, .previewing, .inferring, .cameraLive:
            return false
        default:
            return true
        }
    }

    private var homePhaseSpacing: CGFloat {
        if case .idle = orchestrator.phase { return 0 }
        return 10
    }

    private var homeColumn: some View {
        Group {
            if case .result = orchestrator.phase {
                PeekHomeResultView(
                    orchestrator: orchestrator,
                    setup: setup,
                    showsFullConversation: $showsFullConversation,
                    followUpText: $followUpText,
                    isFollowUpComposerVisible: $isFollowUpComposerVisible,
                    isBriefComposerVisible: $isBriefComposerVisible,
                    briefDraft: $briefDraft,
                    focusFollowUpField: $isFollowUpFieldFocused,
                    focusBriefField: $isBriefFieldFocused,
                    onToggleHistory: { setHistoryVisible(!showsFullConversation) },
                    onFinishChat: finishChat,
                    onRequestNewChat: requestNewChat
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    PeekFadedScrollView(maxHeight: PeekPanelLayout.idleHomeMaxHeight) {
                        idleScrollContent
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: homePhaseSpacing) {
                        PeekHomePhaseContent(
                            orchestrator: orchestrator,
                            showsFullConversation: showsFullConversation,
                            canRetry: setup.isReady,
                            onRecover: handleRecovery
                        )
                        if case .idle = orchestrator.phase {
                            PeekIdleCommandBar(
                                orchestrator: orchestrator,
                                setup: setup,
                                settings: settings,
                                modelCatalog: modelCatalog,
                                pendingDownload: $pendingDownload,
                                isBriefComposerVisible: $isBriefComposerVisible,
                                briefDraft: $briefDraft,
                                focusBriefField: $isBriefFieldFocused,
                                onBrowseModels: openModelLibrary,
                                onCapture: { orchestrator.beginCapture() },
                                onResume: resumeChat
                            )
                            .padding(.top, 4)
                        } else if case .cameraLive = orchestrator.phase {
                            // The live-camera bar has its OWN dispatch (.cancel must tear the
                            // session down) — never route it through PeekHomeActiveControls.
                            PeekCameraLiveControls(orchestrator: orchestrator)
                        } else {
                            PeekHomeActiveControls(
                                orchestrator: orchestrator,
                                setup: setup,
                                onConfirmPreview: { orchestrator.confirmPreview() },
                                onCancel: { orchestrator.cancel() }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: orchestrator.lastNotice)
        .animation(.easeOut(duration: 0.2), value: orchestrator.contextPressure)
    }

    @ViewBuilder
    private var idleScrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .idle = orchestrator.phase {
                PeekIdleHomeContent(settings: orchestrator.settings)
            }
            if !setup.isReady {
                setupBanner
                    .padding(.top, 8)
            }
            if orchestrator.settings.persistConversation, let issue = orchestrator.archivePersistenceIssue {
                PeekArchivePersistenceBanner(
                    message: issue.userFacingMessage,
                    onDismiss: orchestrator.dismissArchivePersistenceIssue
                )
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let notice = orchestrator.lastNotice {
                PeekSessionNoticeBanner(
                    notice: notice,
                    conversationArchived: orchestrator.settings.persistConversation,
                    onDismiss: { withAnimation(.easeOut(duration: 0.2)) { orchestrator.clearNotice() } }
                )
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if case .idle = orchestrator.phase,
               orchestrator.hasConversation,
               orchestrator.contextPressure != .normal {
                PeekContextWarningBanner(
                    pressure: orchestrator.contextPressure,
                    fraction: orchestrator.contextFraction ?? 0,
                    onStartNewChat: requestNewChat
                )
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if PracticeMode.shipped.count > 1 {
                modePicker
                    .padding(.top, 8)
            }
        }
    }

    private var setupBanner: some View {
        Button(action: setupBannerAction) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange.opacity(0.9))
                Text("\(setupStatusDetail)")
                    .foregroundStyle(theme.tertiaryLabel)
                Text(setupBannerActionLabel)
                    .foregroundStyle(.orange)
                    .underline()
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.75))
            }
            .font(.system(size: 10, weight: .regular))
        }
        .buttonStyle(.plain)
        .help(setupBannerHelp)
        .accessibilityLabel("\(setupStatusDetail). \(setupBannerHelp)")
    }

    private var setupBannerActionLabel: String {
        if case .failed = setup.captureStep { return "Open settings" }
        return "Get ready"
    }

    private var setupBannerHelp: String {
        if case .failed = setup.captureStep {
            return "Open Screen Recording settings"
        }
        return "Open setup to finish before capturing"
    }

    private func setupBannerAction() {
        if case .failed = setup.captureStep {
            CapturePermissionStatus.requestScreenRecording()
        } else {
            onOpenSetup()
        }
    }

    /// The most pressing missing prerequisite, surfaced inline so the user knows *what's* incomplete
    /// without drilling into Get ready.
    private var setupStatusDetail: String {
        if case .failed = setup.ollamaStep { return "Ollama offline" }
        if setup.modelStep != .complete { return "Model not installed" }
        if case .failed = setup.captureStep { return "Screen Recording off" }
        return "Setup incomplete"
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
            if orchestrator.settings.usesRemoteOllama {
                PeekSettingsNavigation.openVisionServer(appState: appState)
            } else {
                SetupCoordinator.openOllamaApp()
            }
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
        case .openCameraSettings:
            CapturePermissionStatus.requestCamera()
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

    /// A transient ``SessionNotice`` is informational, not a standing alert — clear it a few seconds
    /// after it lands so it doesn't linger over the home surface. Re-armed on every notice token.
    private func armNoticeAutoDismiss() {
        guard orchestrator.lastNotice != nil else { return }
        noticeDismissTask?.cancel()
        noticeDismissTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) { orchestrator.clearNotice() }
            }
        }
    }

    /// Hold the surface open just long enough for the panel to resize and the cursor to settle, then
    /// release so hover-to-dismiss works normally again.
    private func armKeepOpenGrace() {
        keepOpenGraceTask?.cancel()
        keepOpenGrace = true
        keepOpenGraceTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { keepOpenGrace = false }
        }
    }

    private func closeStats() {
        withAnimation(.easeOut(duration: 0.2)) {
            appState.moduleBreadcrumb = nil
        }
    }

    private func closeModelLibrary() {
        withAnimation(.easeOut(duration: 0.2)) {
            appState.moduleBreadcrumb = nil
        }
    }

    private func openModelLibrary() {
        guard allowsGlobalDrillIn else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            appState.moduleBreadcrumb = Self.modelLibraryBreadcrumb
        }
    }

    private func closeArchive() {
        withAnimation(.easeOut(duration: 0.2)) {
            showsArchive = false
            appState.moduleBreadcrumb = nil
        }
    }

    private func openArchivedThread(_ summary: ConversationSummary) {
        Task {
            await orchestrator.openThread(id: summary.id)
            showsArchive = false
            appState.moduleBreadcrumb = nil
        }
    }
}

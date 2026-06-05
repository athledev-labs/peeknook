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
    @State private var isFollowUpComposerVisible = false
    @State private var showsFullConversation = false
    @State private var showsNewChatConfirmation = false
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
        VStack(alignment: .leading, spacing: 12) {
            if case .idle = orchestrator.phase {
                PeekIdleHomeContent(orchestrator: orchestrator, onResume: resumeChat)
            }
            if !setup.isReady {
                setupBanner
            }
            if PracticeMode.shipped.count > 1 {
                modePicker
            }
            mainColumn
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: orchestrator.phase) { _, newPhase in
            isFollowUpComposerVisible = false
            followUpText = ""
            if case .result = newPhase { return }
            setHistoryVisible(false)
        }
        .onChange(of: appState.moduleBreadcrumb) { _, breadcrumb in
            if breadcrumb == nil, showsFullConversation {
                showsFullConversation = false
            }
        }
        .onDisappear {
            if appState.moduleBreadcrumb == Self.historyBreadcrumb {
                appState.moduleBreadcrumb = nil
            }
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

    @ViewBuilder
    private var mainColumn: some View {
        if case .result = orchestrator.phase {
            PeekHomeResultView(
                orchestrator: orchestrator,
                setup: setup,
                showsFullConversation: $showsFullConversation,
                followUpText: $followUpText,
                isFollowUpComposerVisible: $isFollowUpComposerVisible,
                focusFollowUpField: $isFollowUpFieldFocused,
                onToggleHistory: { setHistoryVisible(!showsFullConversation) },
                onFinishChat: finishChat,
                onRequestNewChat: requestNewChat
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PeekHomePhaseContent(
                    orchestrator: orchestrator,
                    showsFullConversation: showsFullConversation
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if case .idle = orchestrator.phase {
                    PeekIdleCommandBar(
                        orchestrator: orchestrator,
                        setup: setup,
                        settings: settings,
                        onCapture: { orchestrator.beginCapture() },
                        onResume: idleResumeAction
                    )
                } else {
                    PeekHomeActiveControls(
                        orchestrator: orchestrator,
                        setup: setup,
                        onConfirmPreview: { orchestrator.confirmPreview() },
                        onCancel: { orchestrator.cancel() },
                        onRetryCapture: { orchestrator.beginCapture() }
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
                Text("Setup incomplete —")
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

    private func finishChat() {
        orchestrator.finishChat()
        setHistoryVisible(false)
    }

    private func resumeChat() {
        orchestrator.resumeChat()
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
}

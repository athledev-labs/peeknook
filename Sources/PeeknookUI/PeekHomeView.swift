// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

public struct PeekHomeView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    public var moduleDefaults: UserDefaults
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
        moduleDefaults: UserDefaults,
        onOpenSetup: @escaping () -> Void = {}
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.moduleDefaults = moduleDefaults
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
            // Top-bar back clears the breadcrumb — stay in sync with our History toggle.
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
                    orchestrator.settings.mode = mode
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

    @ViewBuilder
    private var mainColumn: some View {
        if case .result = orchestrator.phase {
            resultLayout
        } else {
            VStack(alignment: .leading, spacing: 10) {
                phaseContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                if case .idle = orchestrator.phase {
                    PeekIdleCommandBar(
                        orchestrator: orchestrator,
                        setup: setup,
                        moduleDefaults: moduleDefaults,
                        onCapture: { orchestrator.beginCapture() },
                        onResume: idleResumeAction
                    )
                } else {
                    primaryActionRow
                }
            }
        }
    }

    private var resultLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            conversationView(streaming: false)
            if showsFullConversation {
                ContextThreadChart(points: TurnUsageTimeline.points(from: orchestrator.conversation))
            }
            if !showsFullConversation {
                suggestionPillRow
            }
            resultFooter
        }
    }

    private static let historyBreadcrumb = "History"

    private func setHistoryVisible(_ visible: Bool) {
        withAnimation(.easeOut(duration: 0.2)) {
            showsFullConversation = visible
            appState.moduleBreadcrumb = visible ? Self.historyBreadcrumb : nil
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch orchestrator.phase {
        case .idle:
            EmptyView()
        case .capturing:
            VStack(alignment: .leading, spacing: 8) {
                StageLabel(text: "Capturing the screen…", symbol: "camera.viewfinder")
                AnalyzingSkeleton()
            }
        case .previewing(let preview):
            VStack(alignment: .leading, spacing: 6) {
                Text("Model will see this")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryLabel)
                Text(preview.targetLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let thumb = preview.screenshotBase64.flatMap(CapturePreviewImage.nsImage(from:)) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 180)
                        .background(theme.tertiaryLabel.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(theme.tertiaryLabel.opacity(0.35), lineWidth: 1)
                        )
                } else {
                    Label("No preview image — capture may have failed. Try again.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Text(preview.sourceLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryLabel)
                if !preview.excerpt.isEmpty {
                    Text(preview.excerpt)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        case .inferring:
            VStack(alignment: .leading, spacing: 8) {
                if orchestrator.streamedAnswer.isEmpty {
                    if orchestrator.inferenceModelWasWarm {
                        StageLabel(text: "Reading the screen…", symbol: "viewfinder")
                    } else {
                        StageLabel(text: "Loading the model — first run is slower…", symbol: "hourglass")
                    }
                } else {
                    Label("Answering…", systemImage: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryLabel)
                }
                conversationView(streaming: true)
            }
        case .result:
            EmptyView()
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.85))
        }
    }

    private var resultFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isFollowUpComposerVisible {
                followUpComposer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            resultCommandBar
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isFollowUpComposerVisible)
    }

    private var followUpComposer: some View {
        HStack(spacing: 8) {
            TextField("Ask a follow-up…", text: $followUpText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFollowUpFieldFocused)
                .onSubmit(submitFollowUp)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.tertiaryLabel.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Button(action: submitFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(followUpIsEmpty ? theme.tertiaryLabel : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(followUpIsEmpty)
        }
    }

    private var resultCommandBar: some View {
        HStack(alignment: .center, spacing: 6) {
            contextMeter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if orchestrator.hasConversationHistory {
                        NookToolbarButton(
                            title: "History",
                            symbol: "clock.arrow.circlepath",
                            help: showsFullConversation
                                ? "Show only the latest answer"
                                : "View the full conversation thread",
                            prominent: showsFullConversation
                        ) {
                            setHistoryVisible(!showsFullConversation)
                        }
                    }
                    NookToolbarButton(
                        title: "Capture",
                        symbol: "camera.viewfinder",
                        hotkey: orchestrator.settings.captureHotkey,
                        help: "Capture again from anywhere on your Mac"
                    ) {
                        orchestrator.retake()
                    }
                    .disabled(!setup.isReady)
                    NookToolbarButton(
                        title: "Add",
                        symbol: "photo.badge.plus",
                        help: "Add another screenshot to this chat"
                    ) {
                        orchestrator.addImage()
                    }
                    .disabled(!setup.isReady)
                    NookToolbarButton(
                        title: "Follow",
                        symbol: "bubble.left.and.bubble.right",
                        help: "Ask a follow-up about this answer",
                        prominent: isFollowUpComposerVisible
                    ) {
                        toggleFollowUpComposer()
                    }
                    NookToolbarButton(
                        title: "Done",
                        symbol: "house",
                        help: "End this chat and return to the home screen",
                        prominent: true
                    ) {
                        finishChat()
                    }
                    NookToolbarButton(
                        title: "New chat",
                        symbol: "arrow.counterclockwise",
                        help: "Discard this thread and start fresh"
                    ) {
                        requestNewChat()
                    }
                }
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

    private func toggleFollowUpComposer() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isFollowUpComposerVisible.toggle()
        }
        if isFollowUpComposerVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFollowUpFieldFocused = true
            }
        } else {
            isFollowUpFieldFocused = false
        }
    }

    private var displayTurns: [ChatTurn] {
        showsFullConversation ? orchestrator.conversation : orchestrator.focusedConversationTurns
    }

    private func conversationView(streaming: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !showsFullConversation, let capture = orchestrator.latestAnswerCapture {
                        Label(capture.targetLabel, systemImage: "viewfinder")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.tertiaryLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    ForEach(displayTurns) { turn in
                        turnView(
                            turn,
                            isLatestAssistant: isLatestAssistantTurn(turn, streaming: streaming),
                            showAllTurnTypes: showsFullConversation
                        )
                    }
                    if streaming {
                        if orchestrator.streamedAnswer.isEmpty {
                            AnalyzingSkeleton()
                        } else {
                            answerCard(
                                orchestrator.streamedAnswer,
                                showCopy: true,
                                onCopy: { orchestrator.copyToPasteboard(orchestrator.streamedAnswer) }
                            )
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.answerBottomID)
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .frame(maxHeight: PeekPanelLayout.conversationMaxHeight)
            .onChange(of: orchestrator.streamedAnswer) { _, _ in
                guard streaming else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(Self.answerBottomID, anchor: .bottom)
                }
            }
        }
    }

    private func isLatestAssistantTurn(_ turn: ChatTurn, streaming: Bool) -> Bool {
        guard !streaming, turn.isAssistant else { return false }
        return orchestrator.conversation.last(where: \.isAssistant)?.id == turn.id
    }

    @ViewBuilder
    private func turnView(_ turn: ChatTurn, isLatestAssistant: Bool, showAllTurnTypes: Bool) -> some View {
        switch turn.kind {
        case .image(let capture):
            if showAllTurnTypes {
                Label(capture.targetLabel, systemImage: "viewfinder")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .user(let text):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryLabel)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(theme.tertiaryLabel.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .assistant(let text):
            VStack(alignment: .leading, spacing: 4) {
                answerCard(
                    text,
                    showCopy: isLatestAssistant,
                    onCopy: { orchestrator.copyToPasteboard(text) }
                )
                if showAllTurnTypes, let usage = turn.turnUsage {
                    let previous = TurnUsageTimeline.previousPromptTokens(
                        before: turn.id,
                        in: orchestrator.conversation
                    )
                    TurnUsageChip(
                        usage: usage,
                        promptDelta: usage.promptDelta(sincePreviousPrompt: previous),
                        isFirstAnswer: previous == 0
                    )
                }
            }
        }
    }

    private func answerCard(_ text: String, showCopy: Bool, onCopy: @escaping () -> Void) -> some View {
        AnswerCard(text: text, showCopy: showCopy, onCopy: onCopy)
    }

    @ViewBuilder
    private var suggestionPillRow: some View {
        if !showsFullConversation,
           orchestrator.settings.suggestFollowUps,
           orchestrator.isFetchingSuggestions || !orchestrator.suggestedFollowUps.isEmpty {
            SuggestionPillsRow(
                isLoading: orchestrator.isFetchingSuggestions,
                suggestions: orchestrator.suggestedFollowUps,
                onSelect: { orchestrator.sendFollowUp($0) }
            )
        }
    }

    private var followUpIsEmpty: Bool {
        followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitFollowUp() {
        let text = followUpText
        followUpText = ""
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isFollowUpComposerVisible = false
        }
        isFollowUpFieldFocused = false
        orchestrator.sendFollowUp(text)
    }

    @ViewBuilder
    private var contextMeter: some View {
        if let usage = orchestrator.contextUsage {
            let fraction = min(1, Double(usage.used) / Double(usage.total))
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiaryLabel)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 36)
                    .tint(fraction > 0.85 ? .orange : theme.secondaryLabel)
                Text("\(compactTokens(usage.used))/\(compactTokens(usage.total))")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .help("\(usage.used) / \(usage.total) tokens in context for this chat")
        }
    }

    private func compactTokens(_ n: Int) -> String {
        let k = Double(n) / 1024
        if k < 1 { return "\(n)" }
        return k >= 10 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
    }

    private static let answerBottomID = "peek.answer.bottom"

    @ViewBuilder
    private var primaryActionRow: some View {
        HStack(spacing: 4) {
            switch orchestrator.phase {
            case .idle:
                EmptyView()
            case .previewing:
                NookToolbarButton(title: "Use this", symbol: "checkmark.circle", prominent: true) {
                    orchestrator.confirmPreview()
                }
                NookToolbarButton(title: "Cancel", symbol: "xmark") {
                    orchestrator.cancel()
                }
            case .failed:
                NookToolbarButton(title: "Try again", symbol: "arrow.clockwise", prominent: true) {
                    orchestrator.beginCapture()
                }
                .disabled(!setup.isReady)
            default:
                NookToolbarButton(title: "Cancel", symbol: "xmark") {
                    orchestrator.cancel()
                }
            }
            Spacer(minLength: 0)
        }
    }

}

// MARK: - Answer card

private struct AnswerCard: View {
    @Environment(\.nookResolvedTheme) private var theme
    let text: String
    let showCopy: Bool
    let onCopy: () -> Void
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AnswerMarkdownText(text: text)
                .padding(.trailing, showCopy ? 22 : 0)

            if showCopy {
                Button {
                    onCopy()
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : theme.secondaryLabel)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(didCopy ? "Copied" : "Copy answer")
                .opacity(isHovered || didCopy ? 1 : 0.45)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

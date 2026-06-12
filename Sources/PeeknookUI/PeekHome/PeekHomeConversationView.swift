// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

struct PeekHomeConversationView: View {
    var orchestrator: SessionOrchestrator
    var showsFullConversation: Bool
    var streaming: Bool
    /// When false, render the turns without an inner `ScrollView` so a parent scroll can own the
    /// whole History surface (turns + usage chart) as one scrollable region. Default true.
    var scrolls: Bool = true

    @Environment(\.nookResolvedTheme) private var theme

    private static let answerBottomID = "peek.answer.bottom"

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                PeekScrollView {
                    turnStack
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
        } else {
            turnStack
        }
    }

    private var turnStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            if orchestrator.settings.webLookupEnabled,
               orchestrator.isFetchingWebLookup || orchestrator.webLookupSnapshot != nil {
                PeekWebLookupTableView(
                    snapshot: orchestrator.webLookupSnapshot,
                    isLoading: orchestrator.isFetchingWebLookup
                )
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
                    PeekHomeAnswerCard(
                        text: orchestrator.streamedAnswer,
                        renderMarkdown: orchestrator.settings.renderAnswerMarkdown,
                        showCopy: true,
                        onCopy: { orchestrator.copyToPasteboard(orchestrator.streamedAnswer) }
                    )
                }
            }
            Color.clear.frame(height: 1).id(Self.answerBottomID)
        }
    }

    private var displayTurns: [ChatTurn] {
        showsFullConversation ? orchestrator.conversation : orchestrator.focusedConversationTurns
    }

    private func isLatestAssistantTurn(_ turn: ChatTurn, streaming: Bool) -> Bool {
        guard !streaming, turn.isAssistant else { return false }
        return orchestrator.conversation.last(where: \.isAssistant)?.id == turn.id
    }

    private func readAlongRange(isLatestAssistant: Bool) -> NSRange? {
        guard isLatestAssistant,
              orchestrator.settings.highlightSpeechWhileReading,
              orchestrator.isSpeakingLastAnswer
        else { return nil }
        return orchestrator.speechSpokenRange
    }

    /// The user's words as a bubble — a typed/pill follow-up turn, or a live-promoted frame's folded
    /// question. One renderer so both read identically in the thread.
    private func userBubble(_ text: String) -> some View {
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
    }

    @ViewBuilder
    private func turnView(_ turn: ChatTurn, isLatestAssistant: Bool, showAllTurnTypes: Bool) -> some View {
        switch turn.kind {
        case .image(let capture):
            if showAllTurnTypes {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        capture.ground == .camera ? PeekLocalized("Camera") : capture.targetLabel,
                        systemImage: capture.ground == .camera ? "camera" : "viewfinder"
                    )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tertiaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    CaptureTurnThumbnail(orchestrator: orchestrator, capture: capture)
                    // A live-promoted frame can carry the user's typed question (folded into one prompt
                    // message). Render it here so the user's words stay visible in the thread, the way a
                    // plain follow-up's `.user` turn does — otherwise the question would silently vanish.
                    if let question = turn.question, !question.isEmpty {
                        userBubble(question)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .user(let text):
            userBubble(text)
        case .assistant(let text):
            VStack(alignment: .leading, spacing: 4) {
                PeekHomeAnswerCard(
                    text: text,
                    renderMarkdown: orchestrator.settings.renderAnswerMarkdown,
                    spokenRange: readAlongRange(isLatestAssistant: isLatestAssistant),
                    isReadingAloud: isLatestAssistant && orchestrator.isSpeakingLastAnswer,
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
}

private struct CaptureTurnThumbnail: View {
    @Environment(\.nookResolvedTheme) private var theme
    var orchestrator: SessionOrchestrator
    let capture: CaptureResult
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.tertiaryLabel.opacity(0.3), lineWidth: 1)
                    )
                    .accessibilityLabel(Text(peek: "Screenshot preview"))
                    .accessibilityAddTraits(.isImage)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: capture.screenshotBlobID) { _, _ in refresh() }
    }

    private func refresh() {
        image = orchestrator.screenshotBase64(for: capture).flatMap(CapturePreviewImage.nsImage(from:))
    }
}

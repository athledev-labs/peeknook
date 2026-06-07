// SPDX-License-Identifier: Apache-2.0

import NookApp
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
                ScrollView {
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
                    PeekHomeAnswerCard(
                        text: orchestrator.streamedAnswer,
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

    @ViewBuilder
    private func turnView(_ turn: ChatTurn, isLatestAssistant: Bool, showAllTurnTypes: Bool) -> some View {
        switch turn.kind {
        case .image(let capture):
            if showAllTurnTypes {
                VStack(alignment: .leading, spacing: 4) {
                    Label(capture.targetLabel, systemImage: "viewfinder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tertiaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let thumb = capture.screenshotBase64.flatMap(CapturePreviewImage.nsImage(from:)) {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(maxHeight: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(theme.tertiaryLabel.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                PeekHomeAnswerCard(
                    text: text,
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

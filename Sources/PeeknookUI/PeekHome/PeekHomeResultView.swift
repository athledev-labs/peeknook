// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

struct PeekHomeResultView: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    @Binding var showsFullConversation: Bool
    @Binding var followUpText: String
    var focusFollowUpField: FocusState<Bool>.Binding
    var onToggleHistory: () -> Void
    var onFinishChat: () -> Void
    var onRequestNewChat: () -> Void

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekHomeConversationView(
                orchestrator: orchestrator,
                showsFullConversation: showsFullConversation,
                streaming: false
            )
            if showsFullConversation {
                ContextThreadChart(points: TurnUsageTimeline.points(from: orchestrator.conversation))
            }
            if !showsFullConversation {
                suggestionPillRow
            }
            resultFooter
        }
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

    private var resultFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !showsFullConversation, orchestrator.contextPressure != .normal {
                PeekContextWarningBanner(
                    pressure: orchestrator.contextPressure,
                    fraction: orchestrator.contextFraction ?? 0,
                    onStartNewChat: onRequestNewChat
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !showsFullConversation {
                followUpComposer
            }
            resultCommandBar
        }
        .animation(.easeOut(duration: 0.2), value: orchestrator.contextPressure)
    }

    /// Always-visible follow-up field — one tap into the field, Enter (or the send button) asks.
    /// No toggle, no hidden shortcut.
    private var followUpComposer: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryLabel)
                .peekDecorative()
            TextField("Ask a follow-up…", text: $followUpText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focusFollowUpField)
                .onSubmit(submitFollowUp)
                .accessibilityLabel(Text("Ask a follow-up"))
            Button(action: submitFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(followUpIsEmpty ? theme.tertiaryLabel : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(followUpIsEmpty)
            .peekAction(label: "Send follow-up")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.tertiaryLabel.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
                            onToggleHistory()
                        }
                    }
                    if showsFullConversation {
                        NookToolbarButton(
                            title: "Export",
                            symbol: "square.and.arrow.up",
                            help: "Copy the whole thread as Markdown"
                        ) {
                            orchestrator.copyConversationMarkdown()
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
                        title: "Done",
                        symbol: "house",
                        help: "End this chat and return to the home screen",
                        prominent: true
                    ) {
                        onFinishChat()
                    }
                    NookToolbarButton(
                        title: "New chat",
                        symbol: "arrow.counterclockwise",
                        help: "Discard this thread and start fresh"
                    ) {
                        onRequestNewChat()
                    }
                }
            }
        }
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
                    .tint(PeekContextTint.color(for: fraction))
                Text("\(compactTokens(usage.used))/\(compactTokens(usage.total))")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .help("\(usage.used) / \(usage.total) tokens in context for this chat")
        }
    }

    private var followUpIsEmpty: Bool {
        followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitFollowUp() {
        guard !followUpIsEmpty else { return }
        let text = followUpText
        followUpText = ""
        focusFollowUpField.wrappedValue = false
        orchestrator.sendFollowUp(text)
    }

    private func compactTokens(_ n: Int) -> String {
        let k = Double(n) / 1024
        if k < 1 { return "\(n)" }
        return k >= 10 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
    }
}

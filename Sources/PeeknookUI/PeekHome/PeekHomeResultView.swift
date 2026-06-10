// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

struct PeekHomeResultView: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    @Binding var showsFullConversation: Bool
    @Binding var followUpText: String
    @Binding var isFollowUpComposerVisible: Bool
    @Binding var isBriefComposerVisible: Bool
    @Binding var briefDraft: String
    var focusFollowUpField: FocusState<Bool>.Binding
    var focusBriefField: FocusState<Bool>.Binding
    var onToggleHistory: () -> Void
    var onFinishChat: () -> Void
    var onRequestNewChat: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @Environment(\.nookContentInsets) private var contentInsets

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
            if let usage = orchestrator.contextUsage {
                PeekContextMeter(used: usage.used, total: usage.total)
            }
            if showsFullConversation {
                fullConversationScroll
            } else {
                collapsedResultScroll
                suggestionPillRow
            }
            resultFooter
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.bottom, contentInsets.bottom)
    }

    /// Collapsed result: the latest answer in one owned, capped scroll region so a long single
    /// answer scrolls in place instead of growing the panel past the notch. The suggestion pills and
    /// command bar stay fixed below it.
    private var collapsedResultScroll: some View {
        PeekFadedScrollView(maxHeight: PeekPanelLayout.resultContentMaxHeight) {
            PeekHomeConversationView(
                orchestrator: orchestrator,
                showsFullConversation: false,
                streaming: false,
                scrolls: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// History view: turns and the usage chart scroll together as one region (capped), so the
    /// chart and per-answer breakdown are always reachable. The command bar stays fixed below.
    private var fullConversationScroll: some View {
        PeekFadedScrollView(maxHeight: PeekPanelLayout.historyMaxHeight) {
            VStack(alignment: .leading, spacing: 8) {
                PeekHomeConversationView(
                    orchestrator: orchestrator,
                    showsFullConversation: true,
                    streaming: false,
                    scrolls: false
                )
                ContextThreadChart(points: TurnUsageTimeline.points(from: orchestrator.conversation))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                refreshSeed: suggestionRefreshSeed,
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
            if isFollowUpComposerVisible {
                followUpComposer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            resultCommandBar
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isFollowUpComposerVisible)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isBriefComposerVisible)
        .animation(.easeOut(duration: 0.2), value: orchestrator.contextPressure)
    }

    /// Revealed by the Follow up command pill, then auto-focused. Enter (or the send button) asks.
    private var followUpComposer: some View {
        HStack(spacing: 8) {
            TextField("Ask a follow-up…", text: $followUpText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focusFollowUpField)
                .onSubmit(submitFollowUp)
                .accessibilityLabel(Text(peek: "Ask a follow-up"))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.tertiaryLabel.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            if orchestrator.settings.voiceInputEnabled {
                PeekVoiceInputButton(orchestrator: orchestrator) { transcript in
                    followUpText = transcript
                    submitFollowUp()
                }
            }
            Button(action: submitFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(followUpIsEmpty ? theme.tertiaryLabel : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(followUpIsEmpty)
            .peekAction(label: "Send follow-up")
        }
    }

    private var resultCommandBar: some View {
        PeekCommandBar(
            placement: .result,
            context: commandContext,
            spacing: 4,
            resolveHotkey: hotkey(for:),
            dynamicHelp: { $0 == .brief ? PeekSessionBriefStrip.buttonHelp(for: orchestrator) : nil },
            dispatch: dispatch(_:)
        )
        .padding(.top, 4)
    }

    /// The reactive inputs the result bar gates on, snapshotted for the pure resolver.
    private var commandContext: CommandBarContext {
        let profile = orchestrator.resolvedActiveProfile
        return CommandBarContext(
            isReady: setup.isReady,
            hasConversationHistory: orchestrator.hasConversationHistory,
            showingFullConversation: showsFullConversation,
            isSpeaking: orchestrator.isSpeakingLastAnswer,
            briefHasContent: !orchestrator.sessionBrief.isEmpty,
            briefComposerVisible: isBriefComposerVisible,
            followUpComposerVisible: isFollowUpComposerVisible,
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
        case .history:  onToggleHistory()
        case .export:   orchestrator.copyConversationMarkdown()
        case .brief:
            PeekSessionBriefStrip.toggleComposer(
                orchestrator: orchestrator,
                isComposerVisible: $isBriefComposerVisible,
                draft: $briefDraft,
                focusField: focusBriefField
            )
        case .followUp: toggleFollowUpComposer()
        case .speak:
            if orchestrator.isSpeakingLastAnswer {
                orchestrator.stopSpeaking()
            } else {
                orchestrator.speakLastAnswer()
            }
        case .done:     onFinishChat()
        case .newChat:  onRequestNewChat()
        default:        break
        }
    }

    private var suggestionRefreshSeed: Int {
        orchestrator.conversation.last(where: \.isAssistant)?.id ?? 0
    }

    private var followUpIsEmpty: Bool {
        followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitFollowUp() {
        guard !followUpIsEmpty else { return }
        let text = followUpText
        followUpText = ""
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isFollowUpComposerVisible = false
        }
        focusFollowUpField.wrappedValue = false
        orchestrator.sendFollowUp(text)
    }

    private func toggleFollowUpComposer() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isFollowUpComposerVisible.toggle()
        }
        if isFollowUpComposerVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusFollowUpField.wrappedValue = true
            }
        } else {
            focusFollowUpField.wrappedValue = false
        }
    }
}

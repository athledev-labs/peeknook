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
    @State private var didCopyThread = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if orchestrator.isLiveArmed {
                liveChip
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
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

    /// Persistent armed indicator — rendered only while a live session is armed (the Stop control lives
    /// in the command bar). Shows the master "Live" state, the auto-respond mode, and, once refreshes
    /// land (later slices), the relative time of the last refresh.
    private var liveChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .peekDecorative()
            Text(peek: "Live")
                .font(.system(size: 11, weight: .semibold))
            Text(verbatim: "·").foregroundStyle(theme.tertiaryLabel).peekDecorative()
            Text(peek: liveAutoRespondOn ? "Auto-respond on" : "Auto-respond off")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryLabel)
            if orchestrator.hasPendingLiveFrame {
                Text(verbatim: "·").foregroundStyle(theme.tertiaryLabel).peekDecorative()
                Text(peek: "Seeing latest screen — ask when ready")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryLabel)
            } else if let refresh = lastLiveRefreshLabel {
                Text(verbatim: "·").foregroundStyle(theme.tertiaryLabel).peekDecorative()
                Text(peek: "Last refresh")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryLabel)
                Text(refresh)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryLabel)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.accent.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(peek: liveChipAccessibilityLabel))
    }

    /// One spoken label for the chip: the armed/auto-respond state, plus the "ask when ready" cue while
    /// a refreshed frame is waiting.
    private var liveChipAccessibilityLabel: String {
        if orchestrator.hasPendingLiveFrame {
            return liveAutoRespondOn
                ? "Live session armed, auto-respond on, seeing latest screen"
                : "Live session armed, auto-respond off, seeing latest screen"
        }
        return liveAutoRespondOn
            ? "Live session armed, auto-respond on"
            : "Live session armed, auto-respond off"
    }

    private var liveAutoRespondOn: Bool {
        orchestrator.livePolicy?.autoRespond ?? false
    }

    /// Locale-formatted relative time of the last live refresh, or nil before the first refresh (always
    /// nil until refresh-capable slices land).
    private var lastLiveRefreshLabel: String? {
        guard let at = orchestrator.lastLiveRefreshAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: at, relativeTo: Date())
    }

    private var resultCommandBar: some View {
        PeekCommandBar(
            placement: .result,
            overrides: orchestrator.resolvedCommandOverrides(for: .result),
            context: commandContext,
            spacing: 4,
            resolveHotkey: hotkey(for:),
            dynamicHelp: { $0 == .brief ? PeekSessionBriefStrip.buttonHelp(for: orchestrator) : nil },
            dispatch: dispatch(_:),
            special: { command in
                guard command.action == .export else { return nil }
                return AnyView(
                    CopyThreadCommandButton(
                        command: command,
                        context: commandContext,
                        didCopy: didCopyThread,
                        onCopy: copyThread
                    )
                )
            }
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
            isContextBlocked: orchestrator.contextPressure == .critical,
            isLiveArmed: orchestrator.isLiveArmed,
            hasPendingLiveFrame: orchestrator.hasPendingLiveFrame,
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
        case .export:   copyThread()
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
        case .retake:   orchestrator.retake()
        case .addImage: orchestrator.addImage()
        case .compositeCapture: orchestrator.beginComposite()
        case .toggleLive: withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { orchestrator.armLive() }
        case .stopLive:   withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { orchestrator.stopLive() }
        case .refreshLive: orchestrator.refreshLive()
        case .answerLive: submitLivePromotion(answerFromPending: true)
        case .updateAndAskLive: submitLivePromotion(answerFromPending: false)
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

    /// The live promote bar actions ("Answer now" / "Update & ask"), each carrying any text already typed
    /// in the follow-up composer as the note (so a typed-but-unsent question isn't lost on a bar press).
    /// Both fold the note identically — only the capture differs (parked frame vs a fresh grab).
    private func submitLivePromotion(answerFromPending: Bool) {
        let note = followUpIsEmpty ? nil : followUpText   // View-local trim — `nilIfEmpty` is Core-internal
        if note != nil {
            followUpText = ""
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                isFollowUpComposerVisible = false
            }
            focusFollowUpField.wrappedValue = false
        }
        if answerFromPending {
            orchestrator.answerLive(note: note)
        } else {
            orchestrator.updateAndAskLive(note: note)
        }
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

    private func copyThread() {
        let markdown = orchestrator.conversationMarkdown()
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        orchestrator.copyConversationMarkdown()
        didCopyThread = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopyThread = false }
    }
}

private struct CopyThreadCommandButton: View {
    let command: CommandDescriptor
    let context: CommandBarContext
    let didCopy: Bool
    let onCopy: () -> Void

    var body: some View {
        NookToolbarButton(
            title: didCopy ? "Copied" : command.resolvedTitleKey(in: context),
            symbol: didCopy ? "checkmark" : command.resolvedSymbol(in: context),
            help: didCopy ? "Copied" : command.resolvedHelpKey(in: context),
            testIdentifier: command.accessibilityIdentifier,
            prominent: command.isProminent(in: context),
            action: onCopy
        )
        .disabled(command.isDisabled(in: context))
    }
}

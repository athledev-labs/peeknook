// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

/// Shared mic control for session brief and follow-up composers.
struct PeekVoiceInputButton: View {
    var orchestrator: SessionOrchestrator
    var onFinalTranscript: (String) -> Void

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Button {
                Task { await toggleListening() }
            } label: {
                Image(systemName: orchestrator.isListeningForVoice ? "mic.fill" : "mic")
                    .font(.system(size: 16))
                    .foregroundStyle(orchestrator.isListeningForVoice ? Color.red.opacity(0.9) : theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(!orchestrator.settings.voiceInputEnabled)
            .peekAction(
                label: orchestrator.isListeningForVoice ? "Stop dictation" : "Start dictation",
                hint: voiceActionHint
            )

            if let issue = orchestrator.voiceInputIssue {
                Text(peek: voiceIssueLabelKey(issue))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryLabel)
                    .lineLimit(1)
                    .help(voiceIssueHelp(issue))
            }
        }
        .help(orchestrator.voiceInputIssue.map(voiceIssueHelp) ?? PeekLocalized("Uses on-device speech recognition"))
    }

    private var voiceActionHint: String {
        if let issue = orchestrator.voiceInputIssue {
            return voiceIssueHelp(issue)
        }
        return PeekLocalized("Uses on-device speech recognition")
    }

    private func voiceIssueLabelKey(_ issue: SpeechRecognitionError) -> LocalizedStringKey {
        switch issue {
        case .onDeviceUnavailable:
            return "On-device speech unavailable"
        case .unavailable:
            return "Speech recognition unavailable"
        case .notAuthorized:
            return "Speech permission denied"
        }
    }

    private func voiceIssueHelp(_ issue: SpeechRecognitionError) -> String {
        switch issue {
        case .onDeviceUnavailable:
            return PeekLocalized("On-device speech models are not available. Download an English dictation language pack in System Settings, then try again.")
        case .unavailable:
            return PeekLocalized("Speech recognition is unavailable right now.")
        case .notAuthorized:
            return PeekLocalized("Allow speech recognition for Peeknook in System Settings.")
        }
    }

    private func toggleListening() async {
        if let final = await orchestrator.toggleVoiceInput(), !final.isEmpty {
            onFinalTranscript(final)
        }
    }
}

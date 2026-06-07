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
            hint: "Uses on-device speech recognition"
        )
    }

    private func toggleListening() async {
        if let final = await orchestrator.toggleVoiceInput(), !final.isEmpty {
            onFinalTranscript(final)
        }
    }
}

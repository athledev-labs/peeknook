// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

struct PeekSettingsInteractionSection: View {
    var orchestrator: SessionOrchestrator
    var settings: PeekSettingsController

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsToggleRow(
                icon: orchestrator.settings.voiceInputEnabled ? "mic.fill" : "mic",
                title: "Voice input",
                detail: "Dictate session briefs and follow-ups on-device",
                isOn: voiceInputBinding
            )

            PeekSettingsToggleRow(
                icon: orchestrator.settings.speakAnswersEnabled ? "speaker.wave.2.fill" : "speaker.wave.2",
                title: "Read answers aloud",
                detail: "Speak assistant answers with on-device text-to-speech",
                isOn: speakAnswersBinding
            )

            if orchestrator.settings.speakAnswersEnabled {
                speechVoiceRow
                PeekSettingsToggleRow(
                    icon: orchestrator.settings.highlightSpeechWhileReading ? "text.word.spacing" : "text.word.spacing",
                    title: "Highlight while reading",
                    detail: "Follow the spoken words in the answer with a live highlight",
                    isOn: highlightSpeechBinding
                )
            }
        }
        .onDisappear {
            orchestrator.stopVoicePreview()
        }
    }

    private var speechVoiceRow: some View {
        let current = SpeechVoiceCatalog.displayName(for: orchestrator.settings.speechVoiceIdentifier)
        return HStack(alignment: .center, spacing: 6) {
            PeekSettingsMenuRow(
                icon: "person.wave.2",
                title: "Reading voice",
                detail: "Pick a voice, then preview how answers will sound",
                value: current
            ) { close in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SpeechVoiceCatalog.options()) { option in
                        Button {
                            settings.setSpeechVoiceIdentifier(option.identifier)
                            orchestrator.previewReadingVoice(voiceIdentifier: option.identifier)
                            close()
                        } label: {
                            HStack {
                                Text(option.menuLabel)
                                    .font(.system(size: 11))
                                Spacer()
                                if option.identifier == orchestrator.settings.speechVoiceIdentifier {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 220)
            }

            Button(action: toggleVoicePreview) {
                Image(systemName: orchestrator.isSpeakingVoicePreview ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(orchestrator.isSpeakingVoicePreview ? Color.red.opacity(0.9) : theme.accent)
            }
            .buttonStyle(.plain)
            .peekAction(
                label: orchestrator.isSpeakingVoicePreview ? "Stop preview" : "Preview reading voice",
                hint: "Plays a short on-device sample with the selected voice"
            )
        }
    }

    private func toggleVoicePreview() {
        if orchestrator.isSpeakingVoicePreview {
            orchestrator.stopSpeaking()
        } else {
            orchestrator.previewReadingVoice()
        }
    }

    private var voiceInputBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.voiceInputEnabled },
            set: { settings.setVoiceInputEnabled($0) }
        )
    }

    private var speakAnswersBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.speakAnswersEnabled },
            set: { settings.setSpeakAnswersEnabled($0) }
        )
    }

    private var highlightSpeechBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.highlightSpeechWhileReading },
            set: { settings.setHighlightSpeechWhileReading($0) }
        )
    }
}

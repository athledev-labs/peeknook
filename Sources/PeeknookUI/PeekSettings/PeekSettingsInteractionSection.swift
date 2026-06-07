// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

struct PeekSettingsInteractionSection: View {
    var orchestrator: SessionOrchestrator
    var settings: PeekSettingsController

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
            }
        }
    }

    private var speechVoiceRow: some View {
        let current = SpeechVoiceCatalog.displayName(for: orchestrator.settings.speechVoiceIdentifier)
        return PeekSettingsMenuRow(
            icon: "person.wave.2",
            title: "Reading voice",
            detail: "Enhanced voices are on-device when macOS has them installed",
            value: current
        ) { close in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SpeechVoiceCatalog.options()) { option in
                    Button {
                        settings.setSpeechVoiceIdentifier(option.identifier)
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
}

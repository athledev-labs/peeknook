// SPDX-License-Identifier: Apache-2.0

#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation

/// Speech domain: on-device voice input (STT), answer read-aloud and the settings voice preview
/// (TTS), and read-along highlighting. Owned by ``SessionOrchestrator``; UI binds to the facade,
/// which delegates here. Observable speech state (`isListeningForVoice`, `isSpeakingLastAnswer`,
/// `speechSpokenRange`, …) stays on the orchestrator so views keep observing one surface.
@MainActor
final class SpeechCoordinator {
    private weak var session: SessionOrchestrator?

    init(session: SessionOrchestrator) {
        self.session = session
    }

    func wireCallbacks() {
        guard let session else { return }
        wireCallbacks(on: session.answerSpeechSynthesizer, tracksAnswer: true)
        if session.previewSpeechSynthesizer as AnyObject !== session.answerSpeechSynthesizer as AnyObject {
            wireCallbacks(on: session.previewSpeechSynthesizer, tracksAnswer: false)
        }
    }

    private func wireCallbacks(on synthesizer: any SpeechSynthesizing, tracksAnswer: Bool) {
        if let stub = synthesizer as? StubSpeechSynthesizer {
            attachCallbacks(to: stub, tracksAnswer: tracksAnswer)
        }
        #if canImport(AVFoundation)
        if let apple = synthesizer as? AppleSpeechSynthesizer {
            attachCallbacks(to: apple, tracksAnswer: tracksAnswer)
        }
        #endif
    }

    private func attachCallbacks(to synthesizer: StubSpeechSynthesizer, tracksAnswer: Bool) {
        synthesizer.onSpeakingChanged = { [weak self] in
            self?.syncAllSpeechUIState()
        }
        if tracksAnswer {
            synthesizer.onSpeakRange = { [weak self] range in
                guard let session = self?.session, session.settings.highlightSpeechWhileReading else { return }
                session.speechSpokenRange = range
            }
        }
    }

    #if canImport(AVFoundation)
    private func attachCallbacks(to synthesizer: AppleSpeechSynthesizer, tracksAnswer: Bool) {
        synthesizer.onSpeakingChanged = { [weak self] in
            self?.syncAllSpeechUIState()
        }
        if tracksAnswer {
            synthesizer.onSpeakRange = { [weak self] range in
                guard let session = self?.session, session.settings.highlightSpeechWhileReading else { return }
                session.speechSpokenRange = range
            }
        }
    }
    #endif

    private func syncAllSpeechUIState() {
        guard let session else { return }
        session.isSpeakingVoicePreview = session.previewSpeechSynthesizer.isSpeaking
        session.isSpeakingLastAnswer = session.answerSpeechSynthesizer.isSpeaking
        if !session.isSpeakingLastAnswer {
            session.speechSpokenRange = nil
        }
    }

    func clearReadAlongHighlight() {
        session?.speechSpokenRange = nil
    }

    /// Toggle on-device dictation for briefs and follow-ups. Returns the final transcript when stopping.
    @discardableResult
    func toggleVoiceInput() async -> String? {
        guard let session else { return nil }
        guard session.moduleEnabled(.voiceInput, for: session.resolvedActiveProfile) else { return nil }
        if session.isListeningForVoice {
            let final = session.speechRecognizer.stopListening()
            session.isListeningForVoice = false
            session.voicePartialTranscript = ""
            return final.isEmpty ? nil : final
        }
        guard await session.speechRecognizer.requestAuthorization() else { return nil }
        session.isListeningForVoice = true
        session.voicePartialTranscript = ""
        session.voiceInputIssue = nil
        do {
            try await session.speechRecognizer.startListening { [weak session] partial in
                Task { @MainActor in
                    session?.voicePartialTranscript = partial
                }
            }
        } catch {
            session.isListeningForVoice = false
            session.voicePartialTranscript = ""
            if let speechError = error as? SpeechRecognitionError {
                session.voiceInputIssue = speechError
            }
        }
        return nil
    }

    func stopVoiceInput() {
        guard let session, session.isListeningForVoice else { return }
        _ = session.speechRecognizer.stopListening()
        session.isListeningForVoice = false
        session.voicePartialTranscript = ""
    }

    /// `runTurn` passes the TURN's gating profile (camera turns gate on the `cameraStudy`
    /// literal); the facade's public overload gates on the active profile for UI-initiated reads.
    func speakLastAnswer(gatedBy profile: GroundProfile) {
        guard let session, session.moduleEnabled(.speakAnswers, for: profile) else { return }
        let text = AnswerDisplayText.plainForSpeech(session.lastAssistantText ?? session.streamedAnswer)
        guard !text.isEmpty else { return }
        stopPreviewSpeech()
        clearReadAlongHighlight()
        session.answerSpeechSynthesizer.stopSpeaking()
        let voice = session.settings.speechVoiceIdentifier.nilIfEmpty
        session.answerSpeechSynthesizer.speak(text, voiceIdentifier: voice)
    }

    /// Speaks a fixed preview line with the chosen voice (or the current setting when nil).
    func previewReadingVoice(voiceIdentifier: String?) {
        guard let session else { return }
        stopVoiceInput()
        session.answerSpeechSynthesizer.stopSpeaking()
        stopPreviewSpeech()
        let voice = voiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? session.settings.speechVoiceIdentifier.nilIfEmpty
        session.previewSpeechSynthesizer.speak(
            SessionOrchestrator.readingVoicePreviewSample,
            voiceIdentifier: voice
        )
    }

    func stopSpeaking() {
        stopPreviewSpeech()
        session?.answerSpeechSynthesizer.stopSpeaking()
        clearReadAlongHighlight()
    }

    /// Stops the settings voice sample without interrupting an in-progress answer read-aloud.
    func stopPreviewSpeech() {
        session?.previewSpeechSynthesizer.stopSpeaking()
    }
}

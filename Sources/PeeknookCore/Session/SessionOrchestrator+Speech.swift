// SPDX-License-Identifier: Apache-2.0

#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation

@MainActor
extension SessionOrchestrator {
    func wireSpeechCallbacks() {
        wireSpeechCallbacks(on: answerSpeechSynthesizer, tracksAnswer: true)
        if previewSpeechSynthesizer as AnyObject !== answerSpeechSynthesizer as AnyObject {
            wireSpeechCallbacks(on: previewSpeechSynthesizer, tracksAnswer: false)
        }
    }

    private func wireSpeechCallbacks(on synthesizer: any SpeechSynthesizing, tracksAnswer: Bool) {
        if let stub = synthesizer as? StubSpeechSynthesizer {
            attachSpeechCallbacks(to: stub, tracksAnswer: tracksAnswer)
        }
        #if canImport(AVFoundation)
        if let apple = synthesizer as? AppleSpeechSynthesizer {
            attachSpeechCallbacks(to: apple, tracksAnswer: tracksAnswer)
        }
        #endif
    }

    private func attachSpeechCallbacks(to synthesizer: StubSpeechSynthesizer, tracksAnswer: Bool) {
        synthesizer.onSpeakingChanged = { [weak self] in
            self?.syncAllSpeechUIState()
        }
        if tracksAnswer {
            synthesizer.onSpeakRange = { [weak self] range in
                guard let self, self.settings.highlightSpeechWhileReading else { return }
                self.speechSpokenRange = range
            }
        }
    }

    #if canImport(AVFoundation)
    private func attachSpeechCallbacks(to synthesizer: AppleSpeechSynthesizer, tracksAnswer: Bool) {
        synthesizer.onSpeakingChanged = { [weak self] in
            self?.syncAllSpeechUIState()
        }
        if tracksAnswer {
            synthesizer.onSpeakRange = { [weak self] range in
                guard let self, self.settings.highlightSpeechWhileReading else { return }
                self.speechSpokenRange = range
            }
        }
    }
    #endif

    private func syncAllSpeechUIState() {
        isSpeakingVoicePreview = previewSpeechSynthesizer.isSpeaking
        isSpeakingLastAnswer = answerSpeechSynthesizer.isSpeaking
        if !isSpeakingLastAnswer {
            speechSpokenRange = nil
        }
    }

    private func clearSpeechHighlight() {
        speechSpokenRange = nil
    }

    public func clearSpeechReadAlongHighlight() {
        clearSpeechHighlight()
    }

    public func setSessionBrief(_ text: String) {
        sessionBrief = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func focusBriefComposer() {
        briefComposerFocusToken += 1
    }

    public func dismissVoiceInputIssue() {
        voiceInputIssue = nil
    }

    /// Toggle on-device dictation for briefs and follow-ups. Returns the final transcript when stopping.
    @discardableResult
    public func toggleVoiceInput() async -> String? {
        guard settings.voiceInputEnabled else { return nil }
        if isListeningForVoice {
            let final = speechRecognizer.stopListening()
            isListeningForVoice = false
            voicePartialTranscript = ""
            return final.isEmpty ? nil : final
        }
        guard await speechRecognizer.requestAuthorization() else { return nil }
        isListeningForVoice = true
        voicePartialTranscript = ""
        voiceInputIssue = nil
        do {
            try await speechRecognizer.startListening { [weak self] partial in
                Task { @MainActor in
                    self?.voicePartialTranscript = partial
                }
            }
        } catch {
            isListeningForVoice = false
            voicePartialTranscript = ""
            if let speechError = error as? SpeechRecognitionError {
                voiceInputIssue = speechError
            }
        }
        return nil
    }

    public func stopVoiceInput() {
        guard isListeningForVoice else { return }
        _ = speechRecognizer.stopListening()
        isListeningForVoice = false
        voicePartialTranscript = ""
    }

    public func speakLastAnswer() {
        guard settings.speakAnswersEnabled else { return }
        let text = AnswerDisplayText.plainForSpeech(lastAssistantText ?? streamedAnswer)
        guard !text.isEmpty else { return }
        stopPreviewSpeech()
        clearSpeechHighlight()
        answerSpeechSynthesizer.stopSpeaking()
        let voice = settings.speechVoiceIdentifier.nilIfEmpty
        answerSpeechSynthesizer.speak(text, voiceIdentifier: voice)
    }

    /// Short on-device sample for the Reading voice picker in Settings.
    public static let readingVoicePreviewSample =
        "This is how I'll read your answers aloud."

    /// Speaks a fixed preview line with the chosen voice (or the current setting when nil).
    public func previewReadingVoice(voiceIdentifier: String? = nil) {
        stopVoiceInput()
        answerSpeechSynthesizer.stopSpeaking()
        stopPreviewSpeech()
        let voice = voiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? settings.speechVoiceIdentifier.nilIfEmpty
        previewSpeechSynthesizer.speak(Self.readingVoicePreviewSample, voiceIdentifier: voice)
    }

    public func stopSpeaking() {
        stopPreviewSpeech()
        answerSpeechSynthesizer.stopSpeaking()
        clearSpeechHighlight()
    }

    /// Stops the settings voice sample without interrupting an in-progress answer read-aloud.
    public func stopVoicePreview() {
        stopPreviewSpeech()
    }

    /// Settings preview only — result UI should use ``isSpeakingLastAnswer``.
    public var isSpeakingAnswer: Bool {
        isSpeakingVoicePreview || isSpeakingLastAnswer
    }

    private func stopPreviewSpeech() {
        previewSpeechSynthesizer.stopSpeaking()
    }

    func stopSpeechOutput() {
        stopSpeaking()
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

// General capture/answer preferences, identity, speech, and hotkeys — the plain
// toggle/value setters that funnel through the shared update/persist seam.
@MainActor
extension PeekSettingsController {
    public func setQuickMode(_ quick: Bool) {
        guard settings.quickMode != quick else { return }
        update { $0.quickMode = quick }
    }

    public func setCaptureScope(_ scope: CaptureScope) {
        guard settings.captureScope != scope else { return }
        update { $0.captureScope = scope }
    }

    public func setMode(_ mode: PracticeMode) {
        guard settings.mode != mode else { return }
        update { $0.mode = mode }
    }

    public func setPreviewBeforeInfer(_ enabled: Bool) {
        guard settings.previewBeforeInfer != enabled else { return }
        update { $0.previewBeforeInfer = enabled }
    }

    public func setSuggestFollowUps(_ enabled: Bool) {
        guard settings.suggestFollowUps != enabled else { return }
        update { $0.suggestFollowUps = enabled }
    }

    public func setPersistConversation(_ enabled: Bool) {
        guard settings.persistConversation != enabled else { return }
        update { $0.persistConversation = enabled }
        // Start saving the current thread immediately, or wipe the whole archive when opting out.
        if enabled {
            orchestrator.persistConversationNow()
        } else {
            orchestrator.purgeAllConversations()
        }
    }

    public func setWebLookupEnabled(_ enabled: Bool) {
        guard settings.webLookupEnabled != enabled else { return }
        update { $0.webLookupEnabled = enabled }
    }

    /// Opt in to the "Screen + camera" capture command (screen + camera asked as one question).
    public func setCompositeCaptureEnabled(_ enabled: Bool) {
        guard settings.compositeCaptureEnabled != enabled else { return }
        update { $0.compositeCaptureEnabled = enabled }
    }

    /// Opt in to hearing system audio: lets a profile add the system-audio ground so a capture also
    /// includes a short, on-device transcript of what is playing. Off by default; the capture gate in
    /// ``CaptureCoordinator`` still excludes `.systemAudio` until this is on, so a profile carrying the
    /// ground keeps capturing only its screen legs until the user flips this.
    public func setSystemAudioEnabled(_ enabled: Bool) {
        guard settings.systemAudioEnabled != enabled else { return }
        update { $0.systemAudioEnabled = enabled }
    }

    /// Opt in to reading the focused window's accessibility tree: lets a profile add the
    /// `.accessibilityTree` ground so a capture also folds in a structured, on-device outline of the
    /// window's roles, labels, and values. Off by default; the capture gate in
    /// ``CompositeCaptureCoordinator`` still excludes `.accessibilityTree` until this is on (and the
    /// provider gates on the Accessibility permission), so a profile carrying the ground keeps capturing
    /// only its other legs until the user flips this.
    public func setAccessibilityTreeEnabled(_ enabled: Bool) {
        guard settings.accessibilityTreeEnabled != enabled else { return }
        update { $0.accessibilityTreeEnabled = enabled }
    }

    public func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.displayName != trimmed else { return }
        update { $0.displayName = trimmed }
    }

    public func setShowGreeting(_ enabled: Bool) {
        guard settings.showGreeting != enabled else { return }
        update { $0.showGreeting = enabled }
    }

    public func setRenderAnswerMarkdown(_ enabled: Bool) {
        guard settings.renderAnswerMarkdown != enabled else { return }
        update { $0.renderAnswerMarkdown = enabled }
    }

    // MARK: - Speech (on-device, opt-in)

    public func setVoiceInputEnabled(_ enabled: Bool) {
        guard settings.voiceInputEnabled != enabled else { return }
        update { $0.voiceInputEnabled = enabled }
        if !enabled { orchestrator.stopVoiceInput() }
    }

    public func setSpeakAnswersEnabled(_ enabled: Bool) {
        guard settings.speakAnswersEnabled != enabled else { return }
        update { $0.speakAnswersEnabled = enabled }
        if !enabled { orchestrator.stopSpeaking() }
    }

    public func setHighlightSpeechWhileReading(_ enabled: Bool) {
        guard settings.highlightSpeechWhileReading != enabled else { return }
        update { $0.highlightSpeechWhileReading = enabled }
        if !enabled { orchestrator.clearSpeechReadAlongHighlight() }
    }

    public func setSpeechVoiceIdentifier(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.speechVoiceIdentifier != trimmed else { return }
        update { $0.speechVoiceIdentifier = trimmed }
    }

    // MARK: - Hotkeys

    public func setBriefHotkey(_ hotkey: CaptureHotkey) {
        guard settings.briefHotkey != hotkey else { return }
        update { $0.briefHotkey = hotkey }
    }

    public func setCaptureHotkey(_ hotkey: CaptureHotkey) {
        guard settings.captureHotkey != hotkey else { return }
        update { $0.captureHotkey = hotkey }
    }

    public func setCameraHotkey(_ hotkey: CaptureHotkey) {
        guard settings.cameraHotkey != hotkey else { return }
        update { $0.cameraHotkey = hotkey }
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
public final class SessionOrchestrator {
    // Read-only outside the module: only the orchestrator's own extensions (other files in this
    // same target — +Capture, +Inference, +Archive) drive the phase machine, so the setter is
    // `internal`, not `private`. `private(set)` would lock out those same-target extension files,
    // since Swift `private` excludes extensions declared outside the property's own file. UI and
    // Host observe these; they never assign them.
    public internal(set) var phase: SessionPhase = .idle
    public internal(set) var streamedAnswer: String = ""
    /// Committed conversation, image turns (each captured screenshot), the user's follow-up
    /// questions, and assistant answers, oldest first. Empty until the first answer lands.
    public internal(set) var conversation: [ChatTurn] = []
    /// Model-proposed next questions for the dynamic action pills; cleared on each new turn.
    public var suggestedFollowUps: [String] = []
    /// True while the separate suggestion pass is in flight (drives pill skeletons in the UI).
    public var isFetchingSuggestions = false
    /// Opt-in web lookup snapshot for the current capture turn (cleared on new chat).
    public var webLookupSnapshot: WebLookupSnapshot?
    /// True while DuckDuckGo HTML lookup is in flight before inference.
    public var isFetchingWebLookup = false
    /// Snapshotted when an inference starts: was the model loaded recently enough to still
    /// be warm? Drives an honest loading label (cold model-load vs warm image-read).
    public var inferenceModelWasWarm = false
    /// Tokens in the last turn's prompt (≈ the whole chat re-sent, images included) and the
    /// model's context window, together the chat's context-usage meter.
    public var lastPromptTokens: Int?
    public var contextWindow: Int?
    var lastInferenceAt: Date?
    var turnCounter = 0

    /// Sticky intent for the active chat — cleared on New chat. In-memory only (not archived).
    public var sessionBrief: String = ""
    /// Partial transcript while voice input is active.
    public var voicePartialTranscript: String = ""
    public var isListeningForVoice = false
    /// Last speech-recognition failure surfaced to the mic control (cleared on retry or dismiss).
    public var voiceInputIssue: SpeechRecognitionError?
    /// True while the answer synthesizer is reading an assistant reply aloud.
    public var isSpeakingLastAnswer = false
    /// True while the settings voice preview sample is playing.
    public var isSpeakingVoicePreview = false
    /// Character range currently spoken for read-along highlighting (utterance plain text).
    public var speechSpokenRange: NSRange?
    /// Bumped when the brief hotkey (or another host action) should open the idle brief composer.
    public var briefComposerFocusToken = 0
    /// Set when the opt-in archive fails to save; cleared on the next successful save or dismiss.
    public var archivePersistenceIssue: ConversationArchiveError?

    public var settings: PeeknookSettings
    public weak var setup: SetupCoordinator?
    public var usage: UsageStore?
    /// Opt-in local conversation archive (see `PeeknookSettings.persistConversation`). Stores every
    /// answered chat as its own thread so the user can list, resume, and delete past chats.
    public var conversationArchive: ConversationArchiveStore?
    /// Identity of the chat currently on screen within the archive. Assigned on first save, carried
    /// across follow-ups, cleared when a fresh chat begins. Nil means "not yet archived".
    var activeThreadID: UUID?
    var activeThreadCreatedAt: Date?

    let capture: any CaptureProviding
    let inference: any InferenceEngine
    let speechRecognizer: any SpeechRecognizing
    let answerSpeechSynthesizer: any SpeechSynthesizing
    let previewSpeechSynthesizer: any SpeechSynthesizing
    let webSearch = WebSearchClient()
    var inferenceTask: Task<Void, Never>?
    var suggestionTask: Task<Void, Never>?
    var archiveIOTask: Task<Void, Never>?
    /// Bumped on cancel so a late capture task cannot commit after the user aborts.
    var captureGeneration = 0
    /// Coarser epoch than ``captureGeneration``: bumped whenever in-flight session work is
    /// invalidated (`abortSessionWork`) or a new capture begins. Async completions that span an
    /// await — a streaming token, a launch restore, an archive load — snapshot it before suspending
    /// and bail if it changed, so they can't mutate state after the user moved on.
    var sessionGeneration = 0
    var isPrewarming = false

    /// Last transient, one-shot signal for the UI (e.g. a toast/banner) that isn't part of the
    /// persistent ``SessionPhase``. `noticeToken` increments on every emit so the UI can react even
    /// to a repeat of the same notice; the UI clears it via ``clearNotice()`` after presenting.
    public internal(set) var lastNotice: SessionNotice?
    public internal(set) var noticeToken = 0
    var pendingPreview: CapturePreview?
    var pendingCapture: CaptureResult?
    var pendingIntent: CaptureIntent = .fresh

    /// Whether a capture starts a new chat or extends the current one.
    enum CaptureIntent {
        case fresh      // replace the conversation (first capture / Retake)
        case addToChat  // append a screenshot to the current conversation (Add image)
    }

    /// Context-usage meter for the current chat, or nil until we know both numbers.
    public var contextUsage: (used: Int, total: Int)? {
        guard let used = lastPromptTokens, let total = contextWindow, total > 0 else { return nil }
        return (used, total)
    }

    /// Share of the model context window the current chat already fills (0…1), or nil if unknown.
    public var contextFraction: Double? {
        guard let usage = contextUsage else { return nil }
        return min(1, Double(usage.used) / Double(usage.total))
    }

    /// Pre-capture pressure on the model's context window. Drives a proactive nudge to start a new
    /// chat *before* the next capture or follow-up pushes the thread past the limit. Thresholds line
    /// up with `PeekContextTint` (calm < 0.8, high ≥ 0.8 orange, critical ≥ 0.9 red).
    public enum ContextPressure: Sendable, Equatable {
        case normal
        case high
        case critical
    }

    public var contextPressure: ContextPressure {
        guard let fraction = contextFraction else { return .normal }
        switch fraction {
        case ..<0.8: return .normal
        case ..<0.9: return .high
        default: return .critical
        }
    }

    /// True once there's an answered chat the user can extend or restart.
    public var hasConversation: Bool {
        conversation.contains { if case .assistant = $0.kind { return true } else { return false } }
    }

    /// Collapsed notch view: only the latest assistant answer (full thread via History in UI).
    public var focusedConversationTurns: [ChatTurn] {
        guard let last = conversation.last(where: \.isAssistant) else { return conversation }
        return [last]
    }

    /// Screenshot that grounds the latest assistant answer, if the thread includes one.
    public var latestAnswerCapture: CaptureResult? {
        guard let lastIdx = conversation.lastIndex(where: \.isAssistant) else { return nil }
        for turn in conversation[..<lastIdx].reversed() {
            if case .image(let capture) = turn.kind { return capture }
        }
        return nil
    }

    /// Whether the thread has more to show than the latest answer alone.
    public var hasConversationHistory: Bool {
        conversation.count > 1
    }

    public init(
        settings: PeeknookSettings,
        capture: any CaptureProviding,
        inference: any InferenceEngine,
        speechRecognizer: any SpeechRecognizing = StubSpeechRecognizer(),
        speechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer(),
        previewSpeechSynthesizer: (any SpeechSynthesizing)? = nil
    ) {
        self.settings = settings
        self.capture = capture
        self.inference = inference
        self.speechRecognizer = speechRecognizer
        self.answerSpeechSynthesizer = speechSynthesizer
        self.previewSpeechSynthesizer = previewSpeechSynthesizer ?? speechSynthesizer
        wireSpeechCallbacks()
    }

    public func reloadSettings(from defaults: UserDefaults) {
        settings = PeeknookSettings.load(from: defaults)
    }

    public func persistSettings(to defaults: UserDefaults) {
        settings.save(to: defaults)
        setup?.settings = settings
    }

    var lastAssistantText: String? {
        for turn in conversation.reversed() {
            if case .assistant(let text) = turn.kind { return text }
        }
        return nil
    }
}

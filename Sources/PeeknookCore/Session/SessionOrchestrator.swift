// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
public final class SessionOrchestrator {
    // Read-only outside the module: phase is driven by ``SessionPhaseMachine`` via ``applyPhaseEvent``.
    public var phase: SessionPhase { phaseMachine.phase }
    private var phaseMachine = SessionPhaseMachine()
    let lifecycle = SessionLifecycleCoordinator()
    let webLookup: any WebLookupProviding
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
    /// User-profile catalog (set by `PeeknookServices.makeStack`). Nil = built-ins only, which is
    /// exactly the pre-profiles behavior — tests and minimal hosts need not provide one.
    public var profileStore: ProfileStore?
    /// Opt-in local conversation archive (see `PeeknookSettings.persistConversation`). Stores every
    /// answered chat as its own thread so the user can list, resume, and delete past chats.
    public var conversationArchive: ConversationArchiveStore?
    var _captureBlobStore: CaptureBlobStore?
    /// Blob ids written during the current in-memory session (purged on New chat when not archived).
    var sessionBlobIDs = Set<UUID>()
    var screenshotCache: [UUID: String] = [:]
    /// Identity of the chat currently on screen within the archive. Assigned on first save, carried
    /// across follow-ups, cleared when a fresh chat begins. Nil means "not yet archived".
    var activeThreadID: UUID?
    var activeThreadCreatedAt: Date?

    let captureRegistry: GroundRegistry
    /// The live camera session while `.cameraLive` is on screen, nil otherwise. Held here — not as
    /// a phase payload — so `SessionPhase` stays a value-type `Equatable`/`Sendable` enum. Set by
    /// `openCameraLive()`, cleared by `stopCameraPreview()` (the single teardown choke point).
    public internal(set) var activeCameraSession: (any CameraSessionControlling)?
    let inferenceRegistry: InferenceBackendRegistry
    /// The engine for the user's active backend, resolved per call so a backend switch in
    /// Settings takes effect on the next turn without rebuilding the orchestrator.
    var inference: any InferenceEngine {
        inferenceRegistry.engine(for: settings.answerModel.backend)
    }

    /// The active profile resolved against built-ins + the user catalog (unknown/deleted id →
    /// `screen.default`). `.cameraLive`-scoped gates deliberately do NOT use this — they read the
    /// `GroundProfile.cameraStudy` literal (the single profile-source rule).
    public var resolvedActiveProfile: GroundProfile {
        GroundProfile.resolve(
            id: settings.activeProfileID,
            in: profileStore?.catalog.profiles ?? []
        )
    }
    let speechRecognizer: any SpeechRecognizing
    let answerSpeechSynthesizer: any SpeechSynthesizing
    let previewSpeechSynthesizer: any SpeechSynthesizing
    var archiveIOTask: Task<Void, Never>?
    var isPrewarming = false

    /// Last transient, one-shot signal for the UI (e.g. a toast/banner) that isn't part of the
    /// persistent ``SessionPhase``. `noticeToken` increments on every emit so the UI can react even
    /// to a repeat of the same notice; the UI clears it via ``clearNotice()`` after presenting.
    public internal(set) var lastNotice: SessionNotice?
    public internal(set) var noticeToken = 0
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
        captureRegistry: GroundRegistry,
        inferenceRegistry: InferenceBackendRegistry,
        webLookup: any WebLookupProviding = WebLookupRunner(),
        speechRecognizer: any SpeechRecognizing = StubSpeechRecognizer(),
        speechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer(),
        previewSpeechSynthesizer: (any SpeechSynthesizing)? = nil
    ) {
        self.settings = settings
        self.captureRegistry = captureRegistry
        self.inferenceRegistry = inferenceRegistry
        self.webLookup = webLookup
        self.speechRecognizer = speechRecognizer
        self.answerSpeechSynthesizer = speechSynthesizer
        self.previewSpeechSynthesizer = previewSpeechSynthesizer ?? speechSynthesizer
        wireSpeechCallbacks()
    }

    /// One engine for every backend — the single-engine convenience tests and simple hosts use
    /// (mirrors `PeeknookDependencies.testing(inference:)` keeping its single-engine signature).
    public convenience init(
        settings: PeeknookSettings,
        captureRegistry: GroundRegistry,
        inference: any InferenceEngine,
        webLookup: any WebLookupProviding = WebLookupRunner(),
        speechRecognizer: any SpeechRecognizing = StubSpeechRecognizer(),
        speechSynthesizer: any SpeechSynthesizing = StubSpeechSynthesizer(),
        previewSpeechSynthesizer: (any SpeechSynthesizing)? = nil
    ) {
        self.init(
            settings: settings,
            captureRegistry: captureRegistry,
            inferenceRegistry: .uniform(inference),
            webLookup: webLookup,
            speechRecognizer: speechRecognizer,
            speechSynthesizer: speechSynthesizer,
            previewSpeechSynthesizer: previewSpeechSynthesizer
        )
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

    var captureGeneration: Int { lifecycle.captureGeneration }
    var sessionGeneration: Int { lifecycle.sessionGeneration }

    @discardableResult
    func applyPhaseEvent(_ event: SessionEvent) -> SessionTransitionResult {
        let context = SessionTransitionContext(
            hasConversation: hasConversation,
            isContextBlocked: contextPressure == .critical,
            setupReady: setup?.isReady ?? true,
            previewBeforeInfer: settings.previewBeforeInfer,
            pendingCaptureAvailable: lifecycle.pendingCapture != nil
        )
        return phaseMachine.apply(event, context: context)
    }
}

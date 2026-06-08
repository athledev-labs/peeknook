// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
public final class SessionOrchestrator {
    public private(set) var phase: SessionPhase = .idle
    public private(set) var streamedAnswer: String = ""
    /// Committed conversation, image turns (each captured screenshot), the user's follow-up
    /// questions, and assistant answers, oldest first. Empty until the first answer lands.
    public private(set) var conversation: [ChatTurn] = []
    /// Model-proposed next questions for the dynamic action pills; cleared on each new turn.
    public private(set) var suggestedFollowUps: [String] = []
    /// True while the separate suggestion pass is in flight (drives pill skeletons in the UI).
    public private(set) var isFetchingSuggestions = false
    /// Opt-in web lookup snapshot for the current capture turn (cleared on new chat).
    public private(set) var webLookupSnapshot: WebLookupSnapshot?
    /// True while DuckDuckGo HTML lookup is in flight before inference.
    public private(set) var isFetchingWebLookup = false
    /// Snapshotted when an inference starts: was the model loaded recently enough to still
    /// be warm? Drives an honest loading label (cold model-load vs warm image-read).
    public private(set) var inferenceModelWasWarm = false
    /// Tokens in the last turn's prompt (≈ the whole chat re-sent, images included) and the
    /// model's context window, together the chat's context-usage meter.
    public private(set) var lastPromptTokens: Int?
    public private(set) var contextWindow: Int?
    private var lastInferenceAt: Date?
    private var turnCounter = 0

    /// Sticky intent for the active chat — cleared on New chat. In-memory only (not archived).
    public private(set) var sessionBrief: String = ""
    /// Partial transcript while voice input is active.
    public private(set) var voicePartialTranscript: String = ""
    public private(set) var isListeningForVoice = false
    /// Last speech-recognition failure surfaced to the mic control (cleared on retry or dismiss).
    public private(set) var voiceInputIssue: SpeechRecognitionError?
    /// True while the answer synthesizer is reading an assistant reply aloud.
    public private(set) var isSpeakingLastAnswer = false
    /// True while the settings voice preview sample is playing.
    public private(set) var isSpeakingVoicePreview = false
    /// Character range currently spoken for read-along highlighting (utterance plain text).
    public private(set) var speechSpokenRange: NSRange?
    /// Bumped when the brief hotkey (or another host action) should open the idle brief composer.
    public private(set) var briefComposerFocusToken = 0
    /// Set when the opt-in archive fails to save; cleared on the next successful save or dismiss.
    public private(set) var archivePersistenceIssue: ConversationArchiveError?

    public var settings: PeeknookSettings
    public weak var setup: SetupCoordinator?
    public var usage: UsageStore?
    /// Opt-in local conversation archive (see `PeeknookSettings.persistConversation`). Stores every
    /// answered chat as its own thread so the user can list, resume, and delete past chats.
    public var conversationArchive: ConversationArchiveStore?
    /// Identity of the chat currently on screen within the archive. Assigned on first save, carried
    /// across follow-ups, cleared when a fresh chat begins. Nil means "not yet archived".
    private var activeThreadID: UUID?
    private var activeThreadCreatedAt: Date?

    private let capture: any CaptureProviding
    private let inference: any InferenceEngine
    private let speechRecognizer: any SpeechRecognizing
    private let answerSpeechSynthesizer: any SpeechSynthesizing
    private let previewSpeechSynthesizer: any SpeechSynthesizing
    private let webSearch = WebSearchClient()
    private var inferenceTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var archiveIOTask: Task<Void, Never>?
    /// Bumped on cancel so a late capture task cannot commit after the user aborts.
    private var captureGeneration = 0
    private var isPrewarming = false
    private var pendingPreview: CapturePreview?
    private var pendingCapture: CaptureResult?
    private var pendingIntent: CaptureIntent = .fresh

    /// Whether a capture starts a new chat or extends the current one.
    private enum CaptureIntent {
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

    private var isContextBlocked: Bool { contextPressure == .critical }

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

    private func wireSpeechCallbacks() {
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

    private func stopSpeechOutput() {
        stopSpeaking()
    }

    public func reloadSettings(from defaults: UserDefaults) {
        settings = PeeknookSettings.load(from: defaults)
    }

    public func persistSettings(to defaults: UserDefaults) {
        settings.save(to: defaults)
        setup?.settings = settings
    }

    // MARK: - Conversation archive (opt-in, local files)

    /// Restore the most recent saved chat at launch when the user has persistence enabled (migrating
    /// the legacy single-file store first). Leaves the phase at `.idle` so it surfaces as a resumable
    /// thread, not an auto-opened result.
    public func loadPersistedConversationIfEnabled() {
        guard settings.persistConversation, let archive = conversationArchive else { return }
        Task {
            _ = await archive.migrateLegacyIfNeeded()
            guard let restored = await archive.mostRecent(), !restored.turns.isEmpty else { return }
            adopt(restored)
        }
    }

    /// Summaries of every archived chat (newest first) for the History switcher. Empty when
    /// persistence is off or nothing is saved.
    public func availableThreads() async -> [ConversationSummary] {
        guard settings.persistConversation else { return [] }
        guard let archive = conversationArchive else { return [] }
        return await archive.summaries()
    }

    /// Open an archived chat by id: load it into memory and surface its last answer as a result.
    public func openThread(id: UUID) async {
        guard let archive = conversationArchive,
              let thread = await archive.load(id: id),
              !thread.turns.isEmpty else { return }
        inferenceTask?.cancel()
        suggestionTask?.cancel()
        suggestedFollowUps = []
        isFetchingSuggestions = false
        streamedAnswer = ""
        adopt(thread)
        phase = .result(lastAssistantText ?? "")
    }

    /// Delete one archived chat. If it's the one on screen, also clear it from memory and return idle.
    public func deleteThread(id: UUID) {
        enqueueArchiveIO { archive in
            await archive.delete(id: id)
        }
        if id == activeThreadID {
            resetConversation()
            phase = .idle
        }
    }

    private func adopt(_ thread: ConversationThread) {
        conversation = thread.turns
        contextWindow = thread.contextWindow
        lastPromptTokens = thread.lastPromptTokens
        turnCounter = max(thread.turnCounter, thread.turns.map(\.id).max() ?? 0)
        activeThreadID = thread.id
        activeThreadCreatedAt = thread.createdAt
    }

    /// Write the current chat to the archive (off the main actor) when persistence is on; no-op
    /// otherwise. The first save mints the thread's stable id and creation date.
    public func persistConversationNow() {
        guard settings.persistConversation, conversationArchive != nil, !conversation.isEmpty else { return }
        if activeThreadID == nil {
            activeThreadID = UUID()
            activeThreadCreatedAt = Date()
        }
        let thread = ConversationThread(
            id: activeThreadID ?? UUID(),
            createdAt: activeThreadCreatedAt ?? Date(),
            updatedAt: Date(),
            turns: conversation,
            contextWindow: contextWindow,
            turnCounter: turnCounter,
            lastPromptTokens: lastPromptTokens
        )
        enqueueArchiveIO { [self] archive in
            let result = await archive.save(thread)
            await MainActor.run {
                switch result {
                case .success:
                    archivePersistenceIssue = nil
                case .failure(let error):
                    archivePersistenceIssue = error
                }
            }
        }
    }

    public func dismissArchivePersistenceIssue() {
        archivePersistenceIssue = nil
    }

    /// Delete just the chat on screen from the archive, called when the user discards a thread.
    public func discardActiveThread() {
        guard let id = activeThreadID else {
            activeThreadCreatedAt = nil
            return
        }
        enqueueArchiveIO { archive in
            await archive.delete(id: id)
        }
        activeThreadID = nil
        activeThreadCreatedAt = nil
    }

    /// Wipe the whole archive, called when the user turns persistence off or taps Clear all.
    public func purgeAllConversations() {
        enqueueArchiveIO { archive in
            await archive.deleteAll()
        }
        activeThreadID = nil
        activeThreadCreatedAt = nil
    }

    /// Serializes archive read/write so delete/purge cannot race a late save.
    private func enqueueArchiveIO(_ operation: @escaping (ConversationArchiveStore) async -> Void) {
        guard let archive = conversationArchive else { return }
        let prior = archiveIOTask
        archiveIOTask = Task {
            _ = await prior?.value
            guard !Task.isCancelled else { return }
            await operation(archive)
        }
    }

    /// Hotkey / compact affordance entry: capture → preview → infer. Starts a fresh chat only when
    /// there is no answered thread yet; otherwise appends the screenshot to the current session.
    public func beginCapture() {
        switch phase {
        case .idle, .result:
            let intent: CaptureIntent = hasConversation ? .addToChat : .fresh
            guard !isContextBlocked || intent == .fresh else { return }
            startCapture(intent: intent)
        default:
            return
        }
    }

    /// Capture a new screenshot to **replace** the current chat (answer a different screen).
    public func retake() {
        guard case .result = phase else { return }
        startCapture(intent: .fresh)
    }

    /// Capture a new screenshot and **add** it to the current chat (continue with another image).
    public func addImage() {
        guard case .result = phase, !isContextBlocked else { return }
        startCapture(intent: .addToChat)
    }

    /// Leave the result view for the calm home screen while keeping the thread for resume.
    public func finishChat() {
        guard case .result = phase else { return }
        suggestionTask?.cancel()
        streamedAnswer = ""
        pendingPreview = nil
        pendingCapture = nil
        suggestedFollowUps = []
        isFetchingSuggestions = false
        phase = .idle
    }

    /// Return to the last answer when a finished chat is still in memory.
    public func resumeChat() {
        guard case .idle = phase, hasConversation else { return }
        phase = .result(lastAssistantText ?? "")
    }

    /// Discard the current thread and return to idle.
    public func startNewChat() {
        sessionBrief = ""
        dismissResult()
    }

    /// Clear the chat and return to idle, ready for a fresh capture.
    public func restart() {
        startNewChat()
    }

    /// Retry after a failure, re-runs a fresh capture (which re-checks setup readiness).
    public func retryAfterFailure() {
        guard case .failed = phase else { return }
        startCapture(intent: .fresh)
    }

    private func startCapture(intent: CaptureIntent) {
        setup?.refreshCapturePermission()
        if let setup, !setup.isReady {
            phase = .failed(.setupIncomplete)
            return
        }
        inferenceTask?.cancel()
        suggestionTask?.cancel()
        pendingIntent = intent
        streamedAnswer = ""
        stopSpeechOutput()
        phase = .capturing
        captureGeneration += 1
        let generation = captureGeneration

        inferenceTask = Task {
            do {
                let result = try await capture.capture(scope: settings.captureScope, quick: settings.quickMode)
                guard generation == captureGeneration, !Task.isCancelled else { return }
                pendingCapture = result
                pendingPreview = CapturePreview(capture: result)
                if settings.previewBeforeInfer, let preview = pendingPreview {
                    phase = .previewing(preview)
                } else {
                    commitCapture(result, intent: intent)
                }
            } catch is CancellationError {
                return
            } catch let error as CaptureError {
                guard generation == captureGeneration else { return }
                phase = .failed(.from(captureError: error))
            } catch {
                guard generation == captureGeneration else { return }
                phase = .failed(.generic(message: error.localizedDescription))
            }
        }
    }

    public func confirmPreview() {
        guard case .previewing = phase, let capture = pendingCapture else { return }
        commitCapture(capture, intent: pendingIntent)
    }

    /// Appends the confirmed screenshot as an image turn (resetting first for a fresh chat) and
    /// runs the answer.
    private func commitCapture(_ capture: CaptureResult, intent: CaptureIntent) {
        if intent == .fresh { resetConversation() }
        turnCounter += 1
        conversation.append(ChatTurn(id: turnCounter, kind: .image(capture)))
        inferenceTask = Task { await runTurn(capturedNow: capture) }
    }

    /// Ask a follow-up about the chat so far, reuses the screenshots already in the model's
    /// context. Only valid once an answer is on screen.
    public func sendFollowUp(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, case .result = phase, !conversation.isEmpty, !isContextBlocked else { return }
        inferenceTask?.cancel()
        suggestionTask?.cancel()
        suggestedFollowUps = []
        isFetchingSuggestions = false
        turnCounter += 1
        conversation.append(ChatTurn(id: turnCounter, kind: .user(text)))
        inferenceTask = Task { await runTurn(capturedNow: nil) }
    }

    /// Pre-load the model when the notch opens so the user's first capture is warm, not cold.
    /// Idempotent and cheap; no-op when already warm or in flight.
    public func prewarm() {
        guard !modelLikelyWarm, !isPrewarming else { return }
        if let setup, !setup.isReady { return }
        isPrewarming = true
        Task {
            await inference.warmUp(
                model: settings.textModel,
                baseURL: settings.ollamaBaseURL,
                acceptInsecureRemote: settings.acceptInsecureRemoteOllama
            )
            lastInferenceAt = Date() // model is resident now
            isPrewarming = false
        }
    }

    public func cancel() {
        captureGeneration += 1
        inferenceTask?.cancel()
        inferenceTask = nil
        suggestionTask?.cancel()
        streamedAnswer = ""
        stopVoiceInput()
        stopSpeechOutput()
        // Stopping mid-extension (a follow-up or an added image) keeps the answered thread -
        // drop only the unanswered tail and return to the last answer.
        if hasConversation {
            if let last = conversation.last, !last.isAssistant { conversation.removeLast() }
            suggestedFollowUps = []
            isFetchingSuggestions = false
            phase = .result(lastAssistantText ?? "")
            return
        }
        pendingPreview = nil
        pendingCapture = nil
        resetConversation()
        phase = .idle
    }

    public func dismissResult() {
        suggestionTask?.cancel()
        streamedAnswer = ""
        pendingPreview = nil
        pendingCapture = nil
        sessionBrief = ""
        discardActiveThread()
        resetConversation()
        phase = .idle
    }

    /// Clears the in-memory chat and forgets its archive identity (without deleting the archived
    /// thread) so the next answered chat is filed as a new entry.
    private func resetConversation() {
        conversation = []
        suggestedFollowUps = []
        isFetchingSuggestions = false
        webLookupSnapshot = nil
        isFetchingWebLookup = false
        turnCounter = 0
        lastPromptTokens = nil
        activeThreadID = nil
        activeThreadCreatedAt = nil
        stopVoiceInput()
        stopSpeechOutput()
    }

    private var lastAssistantText: String? {
        for turn in conversation.reversed() {
            if case .assistant(let text) = turn.kind { return text }
        }
        return nil
    }

    public func copyAnswerToPasteboard() {
        let text = lastAssistantText ?? streamedAnswer
        copyToPasteboard(text)
    }

    /// The whole thread rendered as Markdown, screenshots become a captioned heading, questions
    /// and answers become labeled blocks. For copy/export of a practice session.
    public func conversationMarkdown() -> String {
        var blocks: [String] = []
        for turn in conversation {
            switch turn.kind {
            case .image(let capture):
                blocks.append("### Screenshot · \(capture.targetLabel)")
            case .user(let text):
                blocks.append("**You:** \(text)")
            case .assistant(let text):
                blocks.append("**Peeknook:**\n\n\(text)")
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    public func copyConversationMarkdown() {
        copyToPasteboard(conversationMarkdown())
    }

    public func copyToPasteboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        #endif
    }

    /// Within Ollama's `keep_alive` window (10m), the model is still resident, so the next
    /// capture skips cold load. 9m margin to stay safely inside it.
    private var modelLikelyWarm: Bool {
        guard let last = lastInferenceAt else { return false }
        return Date().timeIntervalSince(last) < 540
    }

    /// Runs one turn against the conversation so far. `capturedNow` is non-nil when this turn
    /// introduced a new screenshot (first capture or Add image), that drives usage accounting.
    private func runTurn(capturedNow capture: CaptureResult?) async {
        guard !conversation.isEmpty else { return }
        inferenceModelWasWarm = modelLikelyWarm
        phase = .inferring
        streamedAnswer = ""
        webLookupSnapshot = nil

        if settings.webLookupEnabled, let capture {
            let sensitive = SensitiveTextHeuristics.shouldSkipWebLookup(
                text: capture.text,
                windowTitle: capture.windowTitle,
                appName: capture.appName
            )
            if sensitive {
                webLookupSnapshot = WebLookupSnapshot(
                    query: "",
                    results: [],
                    lookupFailed: true,
                    lookupFailure: .sensitiveContent
                )
            } else if let query = WebSearchClient.query(from: capture) {
            isFetchingWebLookup = true
            defer { isFetchingWebLookup = false }
            let allowed = await WebSearchRateLimiter.shared.allowSearch()
            if !allowed {
                webLookupSnapshot = WebLookupSnapshot(
                    query: query,
                    results: [],
                    lookupFailed: true,
                    lookupFailure: .rateLimited
                )
            } else {
                do {
                    let results = try await webSearch.search(query: query)
                    webLookupSnapshot = WebLookupSnapshot(query: query, results: results)
                } catch {
                    webLookupSnapshot = WebLookupSnapshot(
                        query: query,
                        results: [],
                        lookupFailed: true,
                        lookupFailure: .unavailable
                    )
                }
            }
            }
        }

        let inferencePolicy = InferenceReplayPolicy(
            maxImagePayloads: settings.inferenceImageReplay.maxImagePayloads
        )
        let request = InferenceRequest(
            mode: settings.mode,
            messages: inferenceMessages(from: conversation, webLookup: webLookupSnapshot, policy: inferencePolicy),
            model: settings.textModel,
            ollamaBaseURL: settings.ollamaBaseURL,
            quickMode: settings.quickMode,
            acceptInsecureRemoteOllama: settings.acceptInsecureRemoteOllama
        )
        let stream = inference.stream(request: request)

        do {
            var finalStats: InferenceStats?
            var didComplete = false
            for try await event in stream {
                if Task.isCancelled { return }
                switch event {
                case .token(let token):
                    streamedAnswer += token
                    lastInferenceAt = Date() // model is loaded & producing, it's warm now
                case .completed(let stats):
                    finalStats = stats
                    didComplete = true
                }
                if didComplete { break }
            }
            // The stream ends without `.completed` only when cancelled, don't record a
            // phantom capture or flip to a result the user cancelled.
            guard didComplete, !Task.isCancelled else { return }
            lastInferenceAt = Date()
            let answer = streamedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            // Defensive: a misconfigured/reasoning model can stream only hidden thinking and no
            // content. Surface that honestly instead of committing a blank answer bubble.
            guard !answer.isEmpty else {
                phase = .failed(.emptyAnswer)
                return
            }
            // A new screenshot is a capture (image bytes); a text follow-up reuses it (tokens only).
            if let capture {
                usage?.record(capture: capture, inference: finalStats, modelTag: settings.textModel)
            } else {
                usage?.recordFollowUp(inference: finalStats, modelTag: settings.textModel)
            }
            if let prompt = finalStats?.promptTokens, prompt > 0 { lastPromptTokens = prompt }
            turnCounter += 1
            let usage = finalStats.map { TurnUsage(stats: $0, contextWindow: contextWindow) }
            conversation.append(ChatTurn(id: turnCounter, kind: .assistant(answer), turnUsage: usage))
            phase = .result(answer)
            persistConversationNow()
            speakLastAnswer()
            // Suggestions are a separate, schema-constrained pass, kick it off without
            // blocking the answer; pills pop in a moment later.
            fetchSuggestions()
            ensureContextWindowLoaded()
        } catch {
            if !Task.isCancelled {
                phase = .failed(.from(error: error))
            }
        }
    }

    private func promptAssembly(continuingSession: Bool) -> PromptAssembly {
        PromptAssembly(
            answerDepth: AnswerDepth(quickMode: settings.quickMode),
            sessionBrief: sessionBrief.nilIfEmpty,
            continuingSession: continuingSession
        )
    }

    /// Maps the display conversation to the model's message list: each image turn becomes a
    /// grounded user message; only the latest `policy.maxImagePayloads` screenshots ride as
    /// base64 payloads. Older images still get text grounding via `captureUserMessage`.
    private func inferenceMessages(
        from conversation: [ChatTurn],
        webLookup: WebLookupSnapshot? = nil,
        policy: InferenceReplayPolicy = .inference
    ) -> [InferenceMessage] {
        let imageTurnIDs = conversation.filter(\.isImage).map(\.id)
        let replayImageIDs = Set(imageTurnIDs.suffix(policy.maxImagePayloads))
        let lastImageID = imageTurnIDs.last
        return conversation.map { turn in
            switch turn.kind {
            case .image(let capture):
                let lookup = turn.id == lastImageID ? webLookup : nil
                let imageIndex = imageTurnIDs.firstIndex(of: turn.id) ?? 0
                let assembly = promptAssembly(continuingSession: imageIndex > 0)
                let includeImage = replayImageIDs.contains(turn.id)
                return InferenceMessage(
                    role: .user,
                    text: PromptBuilder.captureUserMessage(
                        capture: capture,
                        assembly: assembly,
                        webLookup: lookup
                    ),
                    imageBase64: includeImage ? capture.screenshotBase64 : nil
                )
            case .user(let text):
                return InferenceMessage(
                    role: .user,
                    text: PromptBuilder.followUpUserMessage(
                        question: text,
                        assembly: promptAssembly(continuingSession: false)
                    )
                )
            case .assistant(let text):
                return InferenceMessage(role: .assistant, text: text)
            }
        }
    }

    /// Generates the dynamic action pills for the answer just shown. Controlled only by the
    /// `suggestFollowUps` setting, it's a separate, non-blocking call, so quick mode (which is
    /// about answer terseness) doesn't disable it. Applies only if the same answer is on screen.
    private func fetchSuggestions() {
        suggestionTask?.cancel()
        suggestedFollowUps = []
        guard settings.suggestFollowUps else {
            isFetchingSuggestions = false
            return
        }
        isFetchingSuggestions = true
        let request = InferenceRequest(
            mode: settings.mode,
            messages: inferenceMessages(from: conversation, policy: .suggestions),
            model: settings.textModel,
            ollamaBaseURL: settings.ollamaBaseURL,
            quickMode: settings.quickMode,
            acceptInsecureRemoteOllama: settings.acceptInsecureRemoteOllama
        )
        let expectedTurn = turnCounter
        suggestionTask = Task {
            defer { isFetchingSuggestions = false }
            let result = await inference.generateFollowUps(request: request)
            if Task.isCancelled { return }
            // Only show pills if we're still on the very answer they were generated for.
            guard case .result = phase, turnCounter == expectedTurn else { return }
            suggestedFollowUps = result.suggestions
            attachSuggestionUsage(result.stats, forAnswerTurnID: turnCounter)
        }
    }

    private func attachSuggestionUsage(_ stats: InferenceStats?, forAnswerTurnID turnID: Int) {
        guard let stats, stats.promptTokens > 0 || stats.responseTokens > 0,
              let index = conversation.lastIndex(where: { $0.id == turnID && $0.isAssistant })
        else { return }
        if var usage = conversation[index].turnUsage {
            usage.suggestionPass = stats
            conversation[index].turnUsage = usage
        } else {
            conversation[index].turnUsage = TurnUsage(
                promptTokens: 0,
                responseTokens: 0,
                generationSeconds: 0,
                contextWindow: contextWindow,
                suggestionPass: stats
            )
        }
    }

    /// Look up the model's context window once (cheap, cached for the session).
    private func ensureContextWindowLoaded() {
        guard contextWindow == nil else { return }
        Task {
            if let length = await inference.contextLength(
                model: settings.textModel,
                baseURL: settings.ollamaBaseURL,
                acceptInsecureRemote: settings.acceptInsecureRemoteOllama
            ) {
                contextWindow = length
            }
        }
    }

}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

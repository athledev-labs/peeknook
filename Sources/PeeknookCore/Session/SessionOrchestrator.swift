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
    /// Bumped after each completed archive IO operation so list/chrome views can reload summaries.
    public private(set) var archiveRevision = 0

    public var settings: PeeknookSettings
    public weak var setup: SetupCoordinator?
    public var usage: UsageStore?
    /// User-profile catalog (set by `PeeknookServices.makeStack`). Nil = built-ins only, which is
    /// exactly the pre-profiles behavior — tests and minimal hosts need not provide one.
    public var profileStore: ProfileStore?
    /// Opt-in local conversation archive (see `PeeknookSettings.persistConversation`). Stores every
    /// answered chat as its own thread so the user can list, resume, and delete past chats.
    public var conversationArchive: ConversationArchiveStore?

    let captureRegistry: GroundRegistry
    /// The live camera session while `.cameraLive` is on screen, nil otherwise. Held here — not as
    /// a phase payload — so `SessionPhase` stays a value-type `Equatable`/`Sendable` enum. Set by
    /// `openCameraLive()`, cleared by `stopCameraPreview()` (the single teardown choke point).
    public internal(set) var activeCameraSession: (any CameraSessionControlling)?

    /// The transient state the ephemeral `.captioning` surface renders, or nil when not captioning. Held
    /// here — not as a phase payload — for the same reason as `activeCameraSession`: it keeps
    /// `SessionPhase` a value-type enum. Set by `armCaption()`, cleared by `clearCaptionSurface()` inside
    /// the single disarm choke point. NEVER archived; a caption is ephemeral by construction.
    public internal(set) var liveCaption: CaptionState?
    /// True while the caption surface is armed (a convenience over `liveCaption`, mirroring `isLiveArmed`).
    public var isCaptioning: Bool { liveCaption != nil }

    /// The armed live session, or nil when not armed. Transient — never persisted; set ONLY by an
    /// explicit user toggle (`armLive`, added in a later slice) and cleared by ``stopLiveSession()``.
    /// Its presence is the master "Live" control; Live OFF (nil) is byte-identical to pre-Live.
    public internal(set) var livePolicy: LivePolicy?
    /// True while a live session is armed.
    public var isLiveArmed: Bool { livePolicy != nil }

    /// Seconds left before the mandatory auto-disarm timeout, or `nil` when no cap is set (the
    /// `liveMaxArmedSeconds == 0` default — byte-identical to today, no countdown shown). Floored at 0
    /// so a just-passed deadline reads as 0 rather than negative. Pure given an injected `now`, so the
    /// chip's "N min left" copy is unit-testable without a real clock. See ``LivePolicy/expiresAt``.
    public func liveRemainingSeconds(at now: Date = Date()) -> TimeInterval? {
        guard let expiresAt = livePolicy?.expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(now))
    }
    /// When the last live refresh landed — drives the armed chip's "Last refresh …". Transient.
    public internal(set) var lastLiveRefreshAt: Date?
    /// The issue-stamp of the last auto-response (the rate-cap clock), SEPARATE from `lastLiveRefreshAt`:
    /// a park-only refresh advances `lastLiveRefreshAt` but NOT this, and an auto-answer advances both. `nil`
    /// = none fired this armed session, so the first qualifying timed refresh auto-answers immediately.
    /// Transient — never persisted; cleared on disarm so a fresh arm starts with a clean rate clock.
    public internal(set) var lastAutoResponseAt: Date?
    /// Observable mirror of `lifecycle.pendingLiveCapture != nil`. The pending frame lives in the
    /// non-`@Observable` ``SessionLifecycleCoordinator``, so the result bar's "Answer now" gate and the
    /// chip's "ask when ready" cue need this published flag to re-render. Kept in lockstep with the slot
    /// by routing every park/consume through ``parkPendingLiveFrame(_:)`` / ``takePendingLiveFrame()``
    /// (and the disarm choke point), all reached only while armed — so it is structurally false when
    /// Live is off. Transient.
    public internal(set) var hasPendingLiveFrame = false
    let inferenceRegistry: InferenceBackendRegistry
    /// The engine for the primary vision model's backend (profile binding, else global), resolved
    /// per call so a backend switch or profile switch takes effect on the next turn. Pinned to
    /// ``activeAnswerModel`` — prewarm, suggestions, residency, and context-window look-ups use this.
    /// A per-role turn must instead route through ``inference(for:)`` so the engine follows the
    /// routed endpoint, never `activeAnswerModel`.
    var inference: any InferenceEngine {
        inferenceRegistry.engine(for: activeAnswerModel.backend)
    }

    /// The engine that serves a routed ``InferenceEndpoint``, so a turn's model, endpoint, and engine
    /// can never disagree (e.g. a text-only follow-up bound to a different backend). The seam Live's
    /// `fastVision` reuses to stream from a cheaper backend with no further plumbing.
    func inference(for endpoint: InferenceEndpoint) -> any InferenceEngine {
        inferenceRegistry.engine(for: endpoint)
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
    /// The on-device streaming transcription seam the caption surface drives. Defaults to the
    /// fail-closed ``UnavailableStreamingTranscriber`` so unit-constructed orchestrators and hosts that
    /// don't wire a real one simply can't arm captions (no behavior change).
    let streamingTranscriber: any StreamingTranscribing

    // Internal domain coordinators (see Coordinators/ and internal/engineering/ORCHESTRATOR_SPINE.md).
    // Lazy so each can hold a weak back-reference to the facade; @ObservationIgnored because they
    // are plumbing, not observable state — views observe the facade's published properties only.
    @ObservationIgnored private(set) lazy var speechCoordinator = SpeechCoordinator(session: self)
    @ObservationIgnored private(set) lazy var archiveCoordinator = ArchiveCoordinator(session: self)
    @ObservationIgnored private(set) lazy var cameraCoordinator = CameraCoordinator(session: self)
    @ObservationIgnored private(set) lazy var liveCoordinator = LiveCoordinator(session: self)
    @ObservationIgnored private(set) lazy var captionCoordinator = CaptionCoordinator(session: self)
    @ObservationIgnored private(set) lazy var captureCoordinator = CaptureCoordinator(session: self)
    @ObservationIgnored private(set) lazy var inferenceCoordinator = InferenceCoordinator(session: self)
    /// Watches for critical system memory pressure to release the resident local model. Started by
    /// ``PeeknookServices`` for the running app; nil (never armed) in unit-constructed orchestrators.
    @ObservationIgnored private var memoryPressureMonitor: MemoryPressureMonitor?

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
        previewSpeechSynthesizer: (any SpeechSynthesizing)? = nil,
        streamingTranscriber: any StreamingTranscribing = UnavailableStreamingTranscriber()
    ) {
        self.settings = settings
        self.captureRegistry = captureRegistry
        self.inferenceRegistry = inferenceRegistry
        self.webLookup = webLookup
        self.speechRecognizer = speechRecognizer
        self.answerSpeechSynthesizer = speechSynthesizer
        self.previewSpeechSynthesizer = previewSpeechSynthesizer ?? speechSynthesizer
        self.streamingTranscriber = streamingTranscriber
        speechCoordinator.wireCallbacks()
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
        previewSpeechSynthesizer: (any SpeechSynthesizing)? = nil,
        streamingTranscriber: any StreamingTranscribing = UnavailableStreamingTranscriber()
    ) {
        self.init(
            settings: settings,
            captureRegistry: captureRegistry,
            inferenceRegistry: .uniform(inference),
            webLookup: webLookup,
            speechRecognizer: speechRecognizer,
            speechSynthesizer: speechSynthesizer,
            previewSpeechSynthesizer: previewSpeechSynthesizer,
            streamingTranscriber: streamingTranscriber
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

    func bumpArchiveRevision() {
        archiveRevision += 1
    }

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

    // MARK: - Brief composer

    public func setSessionBrief(_ text: String) {
        sessionBrief = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func focusBriefComposer() {
        briefComposerFocusToken += 1
    }

    // MARK: - Speech (delegates to SpeechCoordinator)

    /// Short on-device sample for the Reading voice picker in Settings.
    public static let readingVoicePreviewSample =
        "This is how I'll read your answers aloud."

    public func clearSpeechReadAlongHighlight() {
        speechCoordinator.clearReadAlongHighlight()
    }

    public func dismissVoiceInputIssue() {
        voiceInputIssue = nil
    }

    /// Toggle on-device dictation for briefs and follow-ups. Returns the final transcript when stopping.
    @discardableResult
    public func toggleVoiceInput() async -> String? {
        await speechCoordinator.toggleVoiceInput()
    }

    public func stopVoiceInput() {
        speechCoordinator.stopVoiceInput()
    }

    public func speakLastAnswer() {
        speechCoordinator.speakLastAnswer(gatedBy: resolvedActiveProfile)
    }

    /// `runTurn` passes the TURN's gating profile (camera turns gate on the `cameraStudy`
    /// literal); the public overload gates on the active profile for UI-initiated reads.
    func speakLastAnswer(gatedBy profile: GroundProfile) {
        speechCoordinator.speakLastAnswer(gatedBy: profile)
    }

    /// Speaks a fixed preview line with the chosen voice (or the current setting when nil).
    public func previewReadingVoice(voiceIdentifier: String? = nil) {
        speechCoordinator.previewReadingVoice(voiceIdentifier: voiceIdentifier)
    }

    public func stopSpeaking() {
        speechCoordinator.stopSpeaking()
    }

    /// Stops the settings voice sample without interrupting an in-progress answer read-aloud.
    public func stopVoicePreview() {
        speechCoordinator.stopPreviewSpeech()
    }

    /// Settings preview only — result UI should use ``isSpeakingLastAnswer``.
    public var isSpeakingAnswer: Bool {
        isSpeakingVoicePreview || isSpeakingLastAnswer
    }

    func stopSpeechOutput() {
        speechCoordinator.stopSpeaking()
    }

    // MARK: - Conversation archive (delegates to ArchiveCoordinator)

    /// Restore the most recent saved chat at launch when the user has persistence enabled (migrating
    /// the legacy single-file store first). Leaves the phase at `.idle` so it surfaces as a resumable
    /// thread, not an auto-opened result.
    public func loadPersistedConversationIfEnabled() {
        archiveCoordinator.loadPersistedConversationIfEnabled()
    }

    /// Summaries of every archived chat (newest first) for the History switcher. Empty when
    /// persistence is off or nothing is saved.
    public func availableThreads() async -> [ConversationSummary] {
        await archiveCoordinator.availableThreads()
    }

    /// Open an archived chat by id: load it into memory and surface its last answer as a result.
    public func openThread(id: UUID) async {
        await archiveCoordinator.openThread(id: id)
    }

    /// Rename one archived chat. Empty title clears a custom name and reverts to the derived label.
    public func renameThread(id: UUID, title: String) {
        archiveCoordinator.renameThread(id: id, title: title)
    }

    /// Delete one archived chat. If it's the one on screen, also clear it from memory and return idle.
    public func deleteThread(id: UUID) {
        archiveCoordinator.deleteThread(id: id)
    }

    /// Write the current chat to the archive (off the main actor) when persistence is on; no-op
    /// otherwise. See ``ArchiveCoordinator/persistConversationNow()``.
    public func persistConversationNow() {
        archiveCoordinator.persistConversationNow()
    }

    public func dismissArchivePersistenceIssue() {
        archivePersistenceIssue = nil
    }

    /// Called when archive bootstrap fails (Keychain unavailable) so the user sees a banner before the first save.
    public func reportArchiveBootstrapFailure(_ error: ConversationArchiveError) {
        archivePersistenceIssue = error
    }

    /// Delete just the chat on screen from the archive, called when the user discards a thread.
    public func discardActiveThread() {
        archiveCoordinator.discardActiveThread()
    }

    /// Wipe the whole archive, called when the user turns persistence off or taps Clear all.
    public func purgeAllConversations() {
        archiveCoordinator.purgeAllConversations()
    }

    /// Identity of the chat currently on screen within the archive (nil = "not yet archived").
    var activeThreadID: UUID? {
        archiveCoordinator.activeThreadID
    }

    // MARK: - Screenshot blobs (delegates to ArchiveCoordinator)

    /// External screenshot storage shared with the conversation archive. Blobs are written only when
    /// ``PeeknookSettings/persistConversation`` is enabled.
    public var captureBlobStore: CaptureBlobStore? {
        get { archiveCoordinator.captureBlobStore }
        set { archiveCoordinator.captureBlobStore = newValue }
    }

    /// Resolved JPEG base64 for a capture turn (inline, cache, or blob file).
    public func screenshotBase64(for capture: CaptureResult) -> String? {
        archiveCoordinator.screenshotBase64(for: capture)
    }

    /// Off-main blob load for History row thumbnails (cache-backed). The disk read runs on a background
    /// task; only the cache check/update and the return hop on the main actor, so scrolling History
    /// doesn't block the main thread per row.
    public func archiveThumbnailBase64(blobID: UUID?) async -> String? {
        await archiveCoordinator.loadArchiveThumbnailBase64(blobID: blobID)
    }

    func storedCapture(_ capture: CaptureResult) -> CaptureResult {
        archiveCoordinator.storedCapture(capture)
    }

    func preloadImageBase64(for turns: [ChatTurn], replayIDs: Set<Int>) -> [Int: String] {
        archiveCoordinator.preloadImageBase64(for: turns, replayIDs: replayIDs)
    }

    func purgeSessionBlobs() {
        archiveCoordinator.purgeSessionBlobs()
    }

    // MARK: - Live camera (delegates to CameraCoordinator)

    /// ⌘⇧C / the camera command: open the live camera preview. Legal from idle/result/failed.
    public func openCameraLive() {
        cameraCoordinator.openCameraLive()
    }

    /// The Shutter command: grab a still from the live session and feed it into the unchanged
    /// commit → runTurn → result pipeline.
    public func shutter() {
        cameraCoordinator.shutter()
    }

    /// Cancel / Escape from the live preview, and the host's unconditional collapse teardown.
    public func cancelCameraLive() {
        cameraCoordinator.cancelCameraLive()
    }

    /// THE single camera teardown choke point (idempotent) — see ``CameraCoordinator``.
    func stopCameraPreview() {
        cameraCoordinator.stopCameraPreview()
    }

    // MARK: - Live session (delegates to LiveCoordinator)

    /// Arm a live session from an answered thread (the "Go live" command). Seeds the policy from the
    /// user's saved preferences; legal only from `.result`. Disarm is ``stopLive()`` / the choke point
    /// ``stopLiveSession()``.
    public func armLive() {
        liveCoordinator.arm()
    }

    /// Disarm the live session (the "Stop" command). Idempotent — see ``stopLiveSession()``.
    public func stopLive() {
        liveCoordinator.stop()
    }

    /// Manual "Refresh" while armed: capture the latest screen into pending context without inferring
    /// or starting a new turn (see ``LiveCoordinator/refresh()``).
    public func refreshLive() {
        liveCoordinator.refresh()
    }

    /// "Answer now": promote the already-parked refreshed frame into an answered turn (optionally with
    /// a note from the follow-up composer). No new capture. No-op when nothing is parked.
    public func answerLive(note: String? = nil) {
        liveCoordinator.answerFromPending(note: note)
    }

    /// "Update & ask": grab the latest screen AND answer in one press, optionally folding a note typed
    /// in the follow-up composer (symmetric with ``answerLive(note:)``). See ``LiveCoordinator/updateAndAsk(note:)``.
    public func updateAndAskLive(note: String? = nil) {
        liveCoordinator.updateAndAsk(note: note)
    }

    /// Park a freshly refreshed frame as the armed chat's pending context and raise the observable
    /// mirror in lockstep. Only ``LiveCoordinator/refresh()`` calls this (while armed).
    func parkPendingLiveFrame(_ capture: CaptureResult) {
        lifecycle.pendingLiveCapture = capture
        lifecycle.pendingLiveCaptureAt = Date()
        hasPendingLiveFrame = true
    }

    /// Atomically take the parked frame and lower the observable mirror in lockstep (nil when none).
    /// Only the live-promotion paths call this (while armed).
    func takePendingLiveFrame() -> CaptureResult? {
        let capture = lifecycle.consumePendingLive()
        hasPendingLiveFrame = false
        return capture
    }

    // MARK: - Live caption (delegates to CaptionCoordinator)

    /// The "Caption" command: arm the ephemeral, local-by-default translated-caption surface. Legal from
    /// idle/result/failed. Refuses (one-shot notice, no phase entry) without a target language or on a
    /// non-opted-in remote route — see ``CaptionCoordinator/arm()``.
    public func armCaption() {
        captionCoordinator.arm()
    }

    /// Stop the caption surface (the "Stop" command) and the host's unconditional collapse teardown.
    /// Idempotent — a no-op outside `.captioning`.
    public func stopCaption() {
        captionCoordinator.stop()
    }

    // MARK: - Capture (delegates to CaptureCoordinator)

    /// Hotkey / compact affordance entry: capture → preview → infer. Starts a fresh chat only when
    /// there is no answered thread yet; otherwise appends the screenshot to the current session.
    public func beginCapture() {
        captureCoordinator.beginCapture()
    }

    /// Import a PDF/image the user picked from disk as a vision turn (the UI presents the open panel
    /// and passes the chosen URL). Skips the screen/camera permission gate — see `Ground.file`.
    public func beginFileImport(url: URL) {
        captureCoordinator.beginFileImport(url: url)
    }

    /// Begin a composite turn (screen + camera asked as one question). Opt-in via
    /// `compositeCaptureEnabled`; captures the screen leg, then opens the live camera for the second.
    public func beginComposite() {
        captureCoordinator.composite.beginComposite()
    }

    /// Commit a composite's screen + camera legs atomically and run one turn — the camera shutter's
    /// composite path (see ``CameraCoordinator``).
    func commitGroupAtShutter(
        screen: CaptureResult, camera: CaptureResult, groupID: UUID, intent: CaptureIntent
    ) {
        captureCoordinator.composite.commitGroupAtShutter(screen: screen, camera: camera, groupID: groupID, intent: intent)
    }

    /// Capture a new screenshot to **replace** the current chat (answer a different screen).
    public func retake() {
        captureCoordinator.retake()
    }

    /// Capture a new screenshot and **add** it to the current chat (continue with another image).
    public func addImage() {
        captureCoordinator.addImage()
    }

    /// Retry after a failure. Re-infers on the last committed screenshot when one exists;
    /// otherwise re-runs capture (which re-checks setup readiness).
    public func retryAfterFailure() {
        captureCoordinator.retryAfterFailure()
    }

    public func confirmPreview() {
        captureCoordinator.confirmPreview()
    }

    /// Appends the confirmed screenshot as an image turn (resetting first for a fresh chat) and
    /// runs the answer. Shared by the screen pipeline and the camera shutter. `question` rides only on
    /// the live-promotion path; every other caller leaves it nil (byte-identical).
    func commitCapture(_ capture: CaptureResult, intent: CaptureIntent, question: String? = nil) {
        captureCoordinator.commitCapture(capture, intent: intent, question: question)
    }

    // MARK: - Inference (delegates to InferenceCoordinator)

    /// Pre-load the model when the notch opens so the user's first capture is warm, not cold.
    /// Idempotent and cheap; no-op when already warm or in flight.
    public func prewarm() {
        inferenceCoordinator.prewarm()
    }

    /// Runs one turn against the conversation so far. `capturedNow` is non-nil when this turn
    /// introduced a new screenshot (first capture or Add image), that drives usage accounting.
    func runTurn(capturedNow capture: CaptureResult?) async {
        await inferenceCoordinator.runTurn(capturedNow: capture)
    }

    /// Refresh whether Ollama `/api/ps` reports the active answer model as loaded in memory.
    func refreshActiveModelResidency() async {
        await inferenceCoordinator.refreshActiveModelResidency()
    }

    /// Warm-model gate for honest loading copy — see ``InferenceCoordinator/modelLikelyWarm``.
    var modelLikelyWarm: Bool {
        inferenceCoordinator.modelLikelyWarm
    }

    /// True while a prewarm pass is in flight (used by tests' polling helpers).
    var isPrewarming: Bool {
        inferenceCoordinator.isPrewarming
    }

    // MARK: - Memory pressure

    /// Begin watching for critical system memory pressure. On a critical event Peeknook releases the
    /// resident *local* model to hand RAM back (see ``handleCriticalMemoryPressure()``). Idempotent;
    /// started by ``PeeknookServices`` for the running app, not by unit-constructed orchestrators.
    public func startMemoryPressureMonitoring() {
        guard memoryPressureMonitor == nil else { return }
        let monitor = MemoryPressureMonitor { [weak self] in
            Task { @MainActor in self?.handleCriticalMemoryPressure() }
        }
        memoryPressureMonitor = monitor
        monitor.start()
    }

    /// Critical memory pressure while idle: free the resident local model so a capture-triggered load
    /// doesn't push the system deeper into swap. No-op when busy (never kill an in-flight answer), for
    /// remote/cloud models (they run off-device), or when nothing is warm to free (also debounces
    /// repeated critical events). Resets the warm gate and tells the user the next capture re-warms.
    func handleCriticalMemoryPressure() {
        let endpoint = activeInferenceEndpoint
        let tag = activeAnswerModel.tag
        guard !endpoint.isRemoteEgress(modelTag: tag), modelLikelyWarm else { return }
        switch phase {
        case .capturing, .previewing, .inferring, .cameraLive, .captioning: return
        default: break
        }
        Task {
            await inference(for: endpoint).unloadModel(model: tag, endpoint: endpoint)
            inferenceCoordinator.markModelUnloaded()
            emitNotice(.modelUnloadedUnderMemoryPressure)
        }
    }
}

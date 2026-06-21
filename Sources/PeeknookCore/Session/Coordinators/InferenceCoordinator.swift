// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Inference domain: the answer turn (vision gate → optional web lookup → streamed answer →
/// archive/speech/suggestions follow-through), the non-blocking suggestion pass, prewarm, and
/// Ollama model-residency tracking. Owned by ``SessionOrchestrator``; UI binds to the facade.
/// Streaming state the UI renders (`streamedAnswer`, `conversation`, `suggestedFollowUps`, the
/// context meter) stays on the orchestrator; this type owns the warm-model bookkeeping.
@MainActor
final class InferenceCoordinator {
    private weak var session: SessionOrchestrator?
    /// The non-blocking follow-up suggestion pass, run after each answer lands.
    private let suggestions: SuggestionCoordinator

    /// When the last token (or successful warm-up) landed — the in-session half of the warm gate.
    private var lastInferenceAt: Date?
    /// True when the active engine reports the active model resident (survives app relaunch).
    private var activeModelResidentInMemory = false
    private(set) var isPrewarming = false

    /// The model tag we last surfaced a "may not fit in memory" notice for. The prewarm loop re-runs
    /// every few seconds while the notch is open, so without this latch a low-memory model re-emits the
    /// banner on every tick (and right after the user taps "Got it"). Warn once per model; cleared when
    /// the model changes, fits again, or warms, so a genuinely new low-memory situation can warn afresh.
    private var memoryWarnedModelTag: String?

    init(session: SessionOrchestrator) {
        self.session = session
        self.suggestions = SuggestionCoordinator(session: session)
    }

    /// Within Ollama's `keep_alive` window, the model is still resident, so the next capture skips
    /// cold load. Also true when the engine confirms the active model is loaded (honest after relaunch
    /// while the backend kept the weights warm). The in-session window tracks the RAM-scaled keep_alive
    /// (`OllamaKeepAlivePolicy`) with a margin, so a low-RAM Mac with a short keep_alive flips to cold
    /// before the weights are actually evicted instead of falsely claiming warm.
    var modelLikelyWarm: Bool {
        if activeModelResidentInMemory { return true }
        guard let last = lastInferenceAt else { return false }
        return Date().timeIntervalSince(last) < OllamaKeepAlivePolicy.recommendedWarmWindowSeconds()
    }

    /// The memory-pressure guard just released the model, so drop both warm signals — the in-session
    /// timer and the residency flag — so the gate honestly reports cold and the next capture re-warms.
    func markModelUnloaded() {
        lastInferenceAt = nil
        activeModelResidentInMemory = false
    }

    /// Refresh whether the active engine reports the active answer model loaded in memory. Backends
    /// that can answer (e.g. Ollama via `/api/ps`) report true/false; those that can't return nil,
    /// which maps to "not resident" so the warm gate falls back to the in-session `lastInferenceAt`
    /// heuristic. Complements that heuristic so a relaunch after the backend kept the model warm
    /// still shows honest "Reading the screen…" copy instead of cold-load text.
    func refreshActiveModelResidency() async {
        guard let session else { return }
        let resident = await session.inference.isModelResident(
            model: session.activeAnswerModel.tag,
            endpoint: session.activeInferenceEndpoint
        )
        activeModelResidentInMemory = (resident == true)
    }

    /// Pre-load the model when the notch opens so the user's first capture is warm, not cold.
    /// Idempotent and cheap; no-op when already warm or in flight.
    func prewarm() {
        guard let session, !isPrewarming else { return }
        if let setup = session.setup, !setup.isReady { return }
        isPrewarming = true
        Task {
            await self.refreshActiveModelResidency()
            guard !self.modelLikelyWarm else {
                // Warm means it fit and loaded, so a later eviction + low memory can warn again.
                self.memoryWarnedModelTag = nil
                self.isPrewarming = false
                return
            }
            // Pre-flight RAM fit-check for a LOCAL model: if its footprint won't fit in free memory,
            // warn the user and DON'T be the one to proactively load a model that could swap-thrash the
            // whole Mac (the actual capture still can, but now the user has a heads-up to free memory or
            // pick a smaller tier first). Remote/cloud models run off-device, so RAM is irrelevant —
            // gate on `isRemoteEgress`. Unknown model size (custom tag) → skip, like the disk pre-check.
            if !session.activeInferenceEndpoint.isRemoteEgress(modelTag: session.activeAnswerModel.tag),
               let option = TextModelCatalog.option(
                   for: session.activeAnswerModel.tag, custom: session.settings.customModels
               ),
               let modelBytes = option.estimatedDownloadBytes {
                let snapshot = SystemMemorySnapshot.current()
                if ModelMemoryPolicy.fit(modelBytes: modelBytes, snapshot: snapshot) == .insufficient {
                    // Warn once per model. The prewarm loop ticks every few seconds, so re-emitting here
                    // would re-pop the banner endlessly (and immediately undo the user's "Got it"). The
                    // latch clears when the model changes, fits, or warms, so a fresh problem still warns.
                    let currentTag = session.activeAnswerModel.tag
                    if self.memoryWarnedModelTag != currentTag {
                        self.memoryWarnedModelTag = currentTag
                        let gb = ModelMemoryPolicy.warningGigabytes(modelBytes: modelBytes, snapshot: snapshot)
                        // Only offer "pick a lighter model" when a smaller curated tier actually exists;
                        // nil here means the user is already on the lightest model, so the banner tells them
                        // to free memory instead of pointing at a model that isn't there.
                        let lighter = TextModelCatalog.leanerAlternative(to: option)?.displayName
                        session.emitNotice(.modelMayNotFitMemory(needGB: gb.needGB, totalGB: gb.totalGB, lighterModel: lighter))
                    }
                    self.isPrewarming = false
                    return
                }
            }
            // Reached warm-up: the model fits (or is remote/unknown-size), so clear any prior warning
            // latch — if it later regresses to low memory, the user should be told again.
            self.memoryWarnedModelTag = nil
            // Endpoint-typed so a backend switch warms the server the next turn actually hits,
            // never a stale Ollama URL.
            let loaded = await session.inference.warmUp(
                model: session.activeAnswerModel.tag,
                endpoint: session.activeInferenceEndpoint
            )
            if loaded { self.lastInferenceAt = Date() }
            await self.refreshActiveModelResidency()
            self.isPrewarming = false
        }
    }

    /// Runs one turn against the conversation so far. `capturedNow` is non-nil when this turn
    /// introduced a new screenshot (first capture or Add image), that drives usage accounting.
    func runTurn(capturedNow capture: CaptureResult?) async {
        guard let session, !session.conversation.isEmpty else { return }
        await refreshActiveModelResidency()
        session.inferenceModelWasWarm = modelLikelyWarm
        guard case .applied = session.applyPhaseEvent(.inferenceStarted) else { return }
        session.streamedAnswer = ""
        session.webLookupSnapshot = nil

        let sessionGen = session.lifecycle.snapshotSession()
        // Snapshot the per-turn answer-depth and brief inputs into a pure message builder shared by
        // this turn's web-lookup gate, replay budgeting, and request assembly.
        let builder = InferenceMessageBuilder(
            quickMode: session.settings.quickMode,
            sessionBrief: session.sessionBrief.nilIfEmpty
        )

        // Don't send a screenshot to a model that can't see it: a text-only model would silently
        // drop the image and answer from text alone. Only the authoritative `/api/show` check
        // blocks (`.textOnly`); an uninstalled or older runtime stays `.unknown` and proceeds
        // (it surfaces its own failure downstream). Gated to capture turns that carry an image.
        if let capture, capture.hasVision {
            let visionGate = VisionGate(inference: session.inference, likelyVision: { _ in false })
            let visionReadiness = await visionGate.readiness(
                of: session.activeAnswerModel.tag,
                endpoint: session.activeInferenceEndpoint
            )
            guard session.lifecycle.isCurrentSession(sessionGen), !Task.isCancelled else { return }
            if visionReadiness == .textOnly {
                _ = session.applyPhaseEvent(.inferenceFailed(.modelLacksVision(tag: session.activeAnswerModel.tag)))
                return
            }
        }

        // Web lookup gates on a SCREEN leg of THIS turn's group, never on incidental nils: a camera
        // frame must not become a search query, yet a multi-ground turn that ran on its camera leg
        // must still search its screen text. Prefer the just-captured leg when it is itself the
        // screen (the common single-screen path stays byte-identical); otherwise reach into the
        // turn's group for a screen leg. The query and the module gate both key on that leg.
        if let capture {
            let lookupLeg: CaptureResult? = capture.ground == .screen
                ? capture
                : builder.latestTurnLegs(in: session.conversation).first { $0.ground == .screen }
            if let lookupLeg,
               session.moduleEnabled(.webLookup, for: session.gatingProfile(forTurnGround: lookupLeg.ground)) {
                session.isFetchingWebLookup = true
                let snapshot = await session.webLookup.lookup(capture: lookupLeg)
                session.isFetchingWebLookup = false
                guard session.lifecycle.isCurrentSession(sessionGen), !Task.isCancelled else { return }
                session.webLookupSnapshot = snapshot
            }
        }

        guard session.lifecycle.isCurrentSession(sessionGen), !Task.isCancelled else { return }

        // Route by role: a pure text follow-up (capture == nil) the user opted into answers with the
        // text-only model. Resolved once here; model, endpoint, and engine all read from `route`, so
        // they can never disagree (the seam-2 fix). A `.primaryVision` turn resolves the identity pair,
        // byte-identical to pre-router behavior.
        let role = session.turnRole(forFollowUp: capture == nil)
        let route = session.routing(for: role)

        // The `.textOnly` route forces replay to 0 so the non-vision model PROVABLY receives no
        // screenshot — zeroing the budget empties `replayImageIDs`, the preload, and the per-message
        // include below in one stroke (the user's explicit fast-follow-up trade: answer from text).
        let inferencePolicy = InferenceReplayPolicy(
            maxImagePayloads: role == .textOnly ? 0 : session.settings.inferenceImageReplay.maxImagePayloads
        )
        let budgeted = ContextBudgetPolicy.trimmedConversation(
            session.conversation,
            pressure: session.contextPressure
        )
        // Budget replay by payload UNIT: a composite group (screen + camera legs) counts as ONE unit,
        // so the latest question replays whole — never half a composite (the group-atomic guard).
        let imageUnits = builder.imagePayloadUnits(budgeted.filter(\.isImage))
        let replayImageIDs = Set(imageUnits.suffix(inferencePolicy.maxImagePayloads).flatMap { $0.map(\.id) })
        var imageBase64ByTurnID = session.preloadImageBase64(for: budgeted, replayIDs: replayImageIDs)
        // Splice the just-captured leg's fresh base64 into ITS OWN turn slot (the freshest copy, in case
        // the blob hasn't flushed yet). It must land on the captured leg's turn — the LAST image turn
        // *that carries vision* — not blindly the last image turn: a screen+audio group ends on the
        // text-only audio turn, which must never receive an image payload.
        if let capture, let base64 = capture.screenshotBase64,
           let latestVisionImageID = budgeted.last(where: { turn in
               guard case .image(let c) = turn.kind else { return false }
               return c.hasVision
           })?.id {
            imageBase64ByTurnID[latestVisionImageID] = base64
        }
        // When this turn streams to a remote host or an Ollama `:cloud` tag, redact secret spans
        // (API keys, tokens, JWTs, PEM, labeled secrets) out of the SENT text legs before assembly.
        // A local/loopback non-cloud turn passes `nil`, so the assembled messages stay byte-identical
        // (no inspection at all). The archived turns and on-screen conversation keep the original text;
        // the screenshot bitmap is out of scope — only text legs are inspected.
        let redaction = route.endpoint.isRemoteEgress(modelTag: route.model.tag)
            ? RedactionContext()
            : nil
        let request = InferenceRequest(
            mode: session.settings.mode,
            agentSystemAppendix: session.activeAgentAppendix,
            profileTemplate: session.activeProfileTemplate,
            messages: builder.inferenceMessages(
                from: budgeted,
                webLookup: session.webLookupSnapshot,
                policy: inferencePolicy,
                imageBase64ByTurnID: imageBase64ByTurnID,
                redaction: redaction
            ),
            model: route.model.tag,
            endpoint: route.endpoint,
            quickMode: session.settings.quickMode
        )
        let redactedSecretCount = redaction?.hitCount ?? 0
        let stream = session.inference(for: route.endpoint).stream(request: request)

        do {
            var finalStats: InferenceStats?
            var didComplete = false
            for try await event in stream {
                if Task.isCancelled { return }
                switch event {
                case .token(let token):
                    session.streamedAnswer += token
                    lastInferenceAt = Date()
                case .completed(let stats):
                    finalStats = stats
                    didComplete = true
                }
                if didComplete { break }
            }
            guard !Task.isCancelled, session.lifecycle.isCurrentSession(sessionGen) else { return }
            guard didComplete else {
                _ = session.applyPhaseEvent(.inferenceFailed(.incompleteAnswerStream))
                return
            }
            lastInferenceAt = Date()
            let answer = session.streamedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                _ = session.applyPhaseEvent(.inferenceEmpty)
                return
            }
            if let capture {
                session.usage?.record(capture: capture, inference: finalStats, modelTag: route.model.tag)
            } else {
                session.usage?.recordFollowUp(inference: finalStats, modelTag: route.model.tag)
            }
            if let prompt = finalStats?.promptTokens, prompt > 0 { session.lastPromptTokens = prompt }
            session.turnCounter += 1
            let turnUsage = finalStats.map { TurnUsage(stats: $0, contextWindow: session.contextWindow) }
            session.conversation.append(
                ChatTurn(id: session.turnCounter, kind: .assistant(answer), turnUsage: turnUsage)
            )
            _ = session.applyPhaseEvent(.inferenceCompleted(answer: answer))
            // Restore the live auto-refresh timer if a persist-across-Done quiesce killed it and this turn
            // re-entered the armed thread via a capture (not Resume) — otherwise an armed `.timer` thread
            // could show the Live chip with a permanently dead loop. Idempotent: a no-op when the loop is
            // already running (normal in-result turns), when not armed, or for a manual-trigger session.
            session.liveCoordinator.ensureTimerLoopRunning()
            // Non-blocking, post-answer: if any secrets were stripped from the remote-bound payload,
            // tell the user. The answer already streamed; this only explains what was withheld.
            if redactedSecretCount > 0 {
                session.emitNotice(.secretsRedactedForRemote(count: redactedSecretCount))
            }
            let turnProfile = session.gatingProfile(forTurnGround: capture?.ground)
            session.persistConversationNow()
            session.speakLastAnswer(gatedBy: turnProfile)
            suggestions.fetchSuggestions(gatedBy: turnProfile)
            ensureContextWindowLoaded()
        } catch {
            if !Task.isCancelled, session.lifecycle.isCurrentSession(sessionGen) {
                _ = session.applyPhaseEvent(
                    .inferenceFailed(.from(error: error, backend: route.model.backend))
                )
            }
        }
    }

    /// Look up the model's context window once (cheap, cached for the session).
    private func ensureContextWindowLoaded() {
        guard let session, session.contextWindow == nil else { return }
        Task {
            if let length = await session.inference.contextLength(
                model: session.activeAnswerModel.tag,
                endpoint: session.activeInferenceEndpoint
            ) {
                session.contextWindow = length
            }
        }
    }
}

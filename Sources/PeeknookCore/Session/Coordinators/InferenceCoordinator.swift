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

    /// When the last token (or successful warm-up) landed — the in-session half of the warm gate.
    private var lastInferenceAt: Date?
    /// True when Ollama `/api/ps` reports the active model resident (survives app relaunch).
    private var activeModelResidentInMemory = false
    /// Injectable in tests so `/api/ps` can be stubbed without hitting the network.
    var residencyClient: OllamaSetupClient?
    private(set) var isPrewarming = false

    init(session: SessionOrchestrator) {
        self.session = session
    }

    /// Within Ollama's `keep_alive` window (10m), the model is still resident, so the next
    /// capture skips cold load. Also true when `/api/ps` confirms the active model is loaded
    /// (honest after relaunch while Ollama kept the weights warm). 9m margin on the timer.
    var modelLikelyWarm: Bool {
        if activeModelResidentInMemory { return true }
        guard let last = lastInferenceAt else { return false }
        return Date().timeIntervalSince(last) < 540
    }

    /// Whether Ollama's `/api/ps` last reported the active answer model as loaded in memory.
    /// Complements the in-session `lastInferenceAt` heuristic so a relaunch after Ollama kept
    /// the model warm still shows honest "Reading the screen…" copy instead of cold-load text.
    func refreshActiveModelResidency() async {
        guard let session else { return }
        switch session.activeInferenceEndpoint {
        case let .ollama(baseURL, acceptInsecureRemote):
            let client = residencyClient ?? OllamaSetupClient()
            let running = (try? await client.runningModelFootprints(
                baseURL: baseURL,
                acceptInsecureRemote: acceptInsecureRemote
            )) ?? []
            activeModelResidentInMemory = OllamaSetupClient.matchesModel(
                installedNames: running.map(\.name),
                wanted: session.activeAnswerModel.tag
            )
        case .openAICompatible:
            activeModelResidentInMemory = false
        }
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
                self.isPrewarming = false
                return
            }
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

        // Web lookup is gated on the ground explicitly, never on incidental nils: a camera frame
        // must not become a search query even once composite turns carry screen text alongside it.
        if let capture, capture.ground == .screen,
           session.moduleEnabled(.webLookup, for: session.gatingProfile(forTurnGround: capture.ground)) {
            session.isFetchingWebLookup = true
            let snapshot = await session.webLookup.lookup(capture: capture)
            session.isFetchingWebLookup = false
            guard session.lifecycle.isCurrentSession(sessionGen), !Task.isCancelled else { return }
            session.webLookupSnapshot = snapshot
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
        let imageTurnIDs = budgeted.filter(\.isImage).map(\.id)
        let replayImageIDs = Set(imageTurnIDs.suffix(inferencePolicy.maxImagePayloads))
        var imageBase64ByTurnID = session.preloadImageBase64(for: budgeted, replayIDs: replayImageIDs)
        if let capture, let latestImageID = imageTurnIDs.last, let base64 = capture.screenshotBase64 {
            imageBase64ByTurnID[latestImageID] = base64
        }
        let request = InferenceRequest(
            mode: session.settings.mode,
            agentSystemAppendix: session.activeAgentAppendix,
            messages: inferenceMessages(
                from: budgeted,
                webLookup: session.webLookupSnapshot,
                policy: inferencePolicy,
                imageBase64ByTurnID: imageBase64ByTurnID
            ),
            model: route.model.tag,
            endpoint: route.endpoint,
            quickMode: session.settings.quickMode
        )
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
            let turnProfile = session.gatingProfile(forTurnGround: capture?.ground)
            session.persistConversationNow()
            session.speakLastAnswer(gatedBy: turnProfile)
            fetchSuggestions(gatedBy: turnProfile)
            ensureContextWindowLoaded()
        } catch {
            if !Task.isCancelled, session.lifecycle.isCurrentSession(sessionGen) {
                _ = session.applyPhaseEvent(
                    .inferenceFailed(.from(error: error, backend: route.model.backend))
                )
            }
        }
    }

    private func promptAssembly(continuingSession: Bool) -> PromptAssembly {
        PromptAssembly(
            answerDepth: AnswerDepth(quickMode: session?.settings.quickMode ?? false),
            sessionBrief: session?.sessionBrief.nilIfEmpty ?? nil,
            continuingSession: continuingSession
        )
    }

    /// Maps the display conversation to the model's message list: each image turn becomes a
    /// grounded user message; only the latest `policy.maxImagePayloads` screenshots ride as
    /// base64 payloads. Older images still get text grounding via `captureUserMessage`.
    private func inferenceMessages(
        from conversation: [ChatTurn],
        webLookup: WebLookupSnapshot? = nil,
        policy: InferenceReplayPolicy = .inference,
        imageBase64ByTurnID: [Int: String] = [:]
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
                    imageBase64: includeImage ? (imageBase64ByTurnID[turn.id] ?? capture.screenshotBase64) : nil
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

    /// Generates the dynamic action pills for the answer just shown. Controlled by the
    /// `suggestFollowUps` module (global setting + the turn profile's override), it's a separate,
    /// non-blocking call, so quick mode (which is about answer terseness) doesn't disable it.
    /// Applies only if the same answer is on screen.
    private func fetchSuggestions(gatedBy turnProfile: GroundProfile) {
        guard let session else { return }
        session.lifecycle.suggestionTask?.cancel()
        session.suggestedFollowUps = []
        guard session.moduleEnabled(.suggestFollowUps, for: turnProfile) else {
            session.isFetchingSuggestions = false
            return
        }
        session.isFetchingSuggestions = true
        // The appendix rides symmetrically; both engines' suggestion pass uses the static
        // follow-up prompt today, so pills stay persona-blind in v1 (recorded seam).
        let request = InferenceRequest(
            mode: session.settings.mode,
            agentSystemAppendix: session.activeAgentAppendix,
            messages: inferenceMessages(from: session.conversation, policy: .suggestions),
            model: session.activeAnswerModel.tag,
            endpoint: session.activeInferenceEndpoint,
            quickMode: session.settings.quickMode
        )
        let expectedTurn = session.turnCounter
        let sessionGen = session.lifecycle.snapshotSession()
        session.lifecycle.suggestionTask = Task {
            defer { session.isFetchingSuggestions = false }
            let result = await session.inference.generateFollowUps(request: request)
            if Task.isCancelled { return }
            guard session.lifecycle.isCurrentSession(sessionGen),
                  case .result = session.phase,
                  session.turnCounter == expectedTurn else { return }
            session.suggestedFollowUps = result.suggestions
            self.attachSuggestionUsage(result.stats, forAnswerTurnID: session.turnCounter)
        }
    }

    private func attachSuggestionUsage(_ stats: InferenceStats?, forAnswerTurnID turnID: Int) {
        guard let session, let stats, stats.promptTokens > 0 || stats.responseTokens > 0,
              let index = session.conversation.lastIndex(where: { $0.id == turnID && $0.isAssistant })
        else { return }
        if var usage = session.conversation[index].turnUsage {
            usage.suggestionPass = stats
            session.conversation[index].turnUsage = usage
        } else {
            session.conversation[index].turnUsage = TurnUsage(
                promptTokens: 0,
                responseTokens: 0,
                generationSeconds: 0,
                contextWindow: session.contextWindow,
                suggestionPass: stats
            )
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

// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
extension SessionOrchestrator {
    /// Within Ollama's `keep_alive` window (10m), the model is still resident, so the next
    /// capture skips cold load. Also true when `/api/ps` confirms the active model is loaded
    /// (honest after relaunch while Ollama kept the weights warm). 9m margin on the timer.
    var modelLikelyWarm: Bool {
        if activeModelResidentInMemory { return true }
        guard let last = lastInferenceAt else { return false }
        return Date().timeIntervalSince(last) < 540
    }

    /// Capture-time vision gate. Only the live `/api/show` capability check can return `.textOnly`,
    /// so the pre-install heuristic is irrelevant to the block decision — a no-op heuristic keeps
    /// it purely authoritative (an uninstalled model stays `.unknown` and never blocks).
    private var visionGate: VisionGate {
        VisionGate(inference: inference, likelyVision: { _ in false })
    }

    /// Runs one turn against the conversation so far. `capturedNow` is non-nil when this turn
    /// introduced a new screenshot (first capture or Add image), that drives usage accounting.
    func runTurn(capturedNow capture: CaptureResult?) async {
        guard !conversation.isEmpty else { return }
        await refreshActiveModelResidency()
        inferenceModelWasWarm = modelLikelyWarm
        guard case .applied = applyPhaseEvent(.inferenceStarted) else { return }
        streamedAnswer = ""
        webLookupSnapshot = nil

        let sessionGen = lifecycle.snapshotSession()

        // Don't send a screenshot to a model that can't see it: a text-only model would silently
        // drop the image and answer from text alone. Only the authoritative `/api/show` check
        // blocks (`.textOnly`); an uninstalled or older runtime stays `.unknown` and proceeds
        // (it surfaces its own failure downstream). Gated to capture turns that carry an image.
        if let capture, capture.hasVision {
            let visionReadiness = await visionGate.readiness(
                of: activeAnswerModel.tag,
                endpoint: activeInferenceEndpoint
            )
            guard lifecycle.isCurrentSession(sessionGen), !Task.isCancelled else { return }
            if visionReadiness == .textOnly {
                _ = applyPhaseEvent(.inferenceFailed(.modelLacksVision(tag: activeAnswerModel.tag)))
                return
            }
        }

        // Web lookup is gated on the ground explicitly, never on incidental nils: a camera frame
        // must not become a search query even once composite turns carry screen text alongside it.
        if let capture, capture.ground == .screen,
           moduleEnabled(.webLookup, for: gatingProfile(forTurnGround: capture.ground)) {
            isFetchingWebLookup = true
            let snapshot = await webLookup.lookup(capture: capture)
            isFetchingWebLookup = false
            guard lifecycle.isCurrentSession(sessionGen), !Task.isCancelled else { return }
            webLookupSnapshot = snapshot
        }

        guard lifecycle.isCurrentSession(sessionGen), !Task.isCancelled else { return }

        let inferencePolicy = InferenceReplayPolicy(
            maxImagePayloads: settings.inferenceImageReplay.maxImagePayloads
        )
        let budgeted = ContextBudgetPolicy.trimmedConversation(conversation, pressure: contextPressure)
        let imageTurnIDs = budgeted.filter(\.isImage).map(\.id)
        let replayImageIDs = Set(imageTurnIDs.suffix(inferencePolicy.maxImagePayloads))
        var imageBase64ByTurnID = preloadImageBase64(for: budgeted, replayIDs: replayImageIDs)
        if let capture, let latestImageID = imageTurnIDs.last, let base64 = capture.screenshotBase64 {
            imageBase64ByTurnID[latestImageID] = base64
        }
        let request = InferenceRequest(
            mode: settings.mode,
            agentSystemAppendix: activeAgentAppendix,
            messages: inferenceMessages(
                from: budgeted,
                webLookup: webLookupSnapshot,
                policy: inferencePolicy,
                imageBase64ByTurnID: imageBase64ByTurnID
            ),
            model: activeAnswerModel.tag,
            endpoint: activeInferenceEndpoint,
            quickMode: settings.quickMode
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
                    lastInferenceAt = Date()
                case .completed(let stats):
                    finalStats = stats
                    didComplete = true
                }
                if didComplete { break }
            }
            guard !Task.isCancelled, lifecycle.isCurrentSession(sessionGen) else { return }
            guard didComplete else {
                _ = applyPhaseEvent(.inferenceFailed(.incompleteAnswerStream))
                return
            }
            lastInferenceAt = Date()
            let answer = streamedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                _ = applyPhaseEvent(.inferenceEmpty)
                return
            }
            if let capture {
                usage?.record(capture: capture, inference: finalStats, modelTag: activeAnswerModel.tag)
            } else {
                usage?.recordFollowUp(inference: finalStats, modelTag: activeAnswerModel.tag)
            }
            if let prompt = finalStats?.promptTokens, prompt > 0 { lastPromptTokens = prompt }
            turnCounter += 1
            let usage = finalStats.map { TurnUsage(stats: $0, contextWindow: contextWindow) }
            conversation.append(ChatTurn(id: turnCounter, kind: .assistant(answer), turnUsage: usage))
            _ = applyPhaseEvent(.inferenceCompleted(answer: answer))
            let turnProfile = gatingProfile(forTurnGround: capture?.ground)
            persistConversationNow()
            speakLastAnswer(gatedBy: turnProfile)
            fetchSuggestions(gatedBy: turnProfile)
            ensureContextWindowLoaded()
        } catch {
            if !Task.isCancelled, lifecycle.isCurrentSession(sessionGen) {
                _ = applyPhaseEvent(
                    .inferenceFailed(.from(error: error, backend: activeAnswerModel.backend))
                )
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
        lifecycle.suggestionTask?.cancel()
        suggestedFollowUps = []
        guard moduleEnabled(.suggestFollowUps, for: turnProfile) else {
            isFetchingSuggestions = false
            return
        }
        isFetchingSuggestions = true
        // The appendix rides symmetrically; both engines' suggestion pass uses the static
        // follow-up prompt today, so pills stay persona-blind in v1 (recorded seam).
        let request = InferenceRequest(
            mode: settings.mode,
            agentSystemAppendix: activeAgentAppendix,
            messages: inferenceMessages(from: conversation, policy: .suggestions),
            model: activeAnswerModel.tag,
            endpoint: activeInferenceEndpoint,
            quickMode: settings.quickMode
        )
        let expectedTurn = turnCounter
        let sessionGen = lifecycle.snapshotSession()
        lifecycle.suggestionTask = Task {
            defer { isFetchingSuggestions = false }
            let result = await inference.generateFollowUps(request: request)
            if Task.isCancelled { return }
            guard lifecycle.isCurrentSession(sessionGen),
                  case .result = phase,
                  turnCounter == expectedTurn else { return }
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
                model: activeAnswerModel.tag,
                endpoint: activeInferenceEndpoint
            ) {
                contextWindow = length
            }
        }
    }
}

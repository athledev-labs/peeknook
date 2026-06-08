// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
extension SessionOrchestrator {
    /// Within Ollama's `keep_alive` window (10m), the model is still resident, so the next
    /// capture skips cold load. 9m margin to stay safely inside it.
    var modelLikelyWarm: Bool {
        guard let last = lastInferenceAt else { return false }
        return Date().timeIntervalSince(last) < 540
    }

    /// Runs one turn against the conversation so far. `capturedNow` is non-nil when this turn
    /// introduced a new screenshot (first capture or Add image), that drives usage accounting.
    func runTurn(capturedNow capture: CaptureResult?) async {
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

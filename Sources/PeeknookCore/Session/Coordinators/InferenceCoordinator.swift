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
    /// True when the active engine reports the active model resident (survives app relaunch).
    private var activeModelResidentInMemory = false
    private(set) var isPrewarming = false

    init(session: SessionOrchestrator) {
        self.session = session
    }

    /// Within Ollama's `keep_alive` window (10m), the model is still resident, so the next
    /// capture skips cold load. Also true when the engine confirms the active model is loaded
    /// (honest after relaunch while the backend kept the weights warm). 9m margin on the timer.
    var modelLikelyWarm: Bool {
        if activeModelResidentInMemory { return true }
        guard let last = lastInferenceAt else { return false }
        return Date().timeIntervalSince(last) < 540
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

        // Web lookup gates on a SCREEN leg of THIS turn's group, never on incidental nils: a camera
        // frame must not become a search query, yet a multi-ground turn that ran on its camera leg
        // must still search its screen text. Prefer the just-captured leg when it is itself the
        // screen (the common single-screen path stays byte-identical); otherwise reach into the
        // turn's group for a screen leg. The query and the module gate both key on that leg.
        if let capture {
            let lookupLeg: CaptureResult? = capture.ground == .screen
                ? capture
                : latestTurnLegs().first { $0.ground == .screen }
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
        let imageUnits = imagePayloadUnits(budgeted.filter(\.isImage))
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
        let request = InferenceRequest(
            mode: session.settings.mode,
            agentSystemAppendix: session.activeAgentAppendix,
            profileTemplate: session.activeProfileTemplate,
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
            // Restore the live auto-refresh timer if a persist-across-Done quiesce killed it and this turn
            // re-entered the armed thread via a capture (not Resume) — otherwise an armed `.timer` thread
            // could show the Live chip with a permanently dead loop. Idempotent: a no-op when the loop is
            // already running (normal in-result turns), when not armed, or for a manual-trigger session.
            session.liveCoordinator.ensureTimerLoopRunning()
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

    /// The image legs of the turn just committed: the trailing run of image turns sharing the final
    /// image turn's `compositeGroupID` (a standalone capture is a one-leg group). Lets the web-lookup
    /// gate find a screen leg even when the turn ran on a non-screen leg (e.g. a composite's camera
    /// leg). A `compositeGroupID` is a fresh UUID per group, so filtering by it never crosses groups.
    private func latestTurnLegs() -> [CaptureResult] {
        guard let session else { return [] }
        let imageTurns = session.conversation.filter(\.isImage)
        guard let last = imageTurns.last else { return [] }
        let legs = last.compositeGroupID.map { group in
            imageTurns.filter { $0.compositeGroupID == group }
        } ?? [last]
        return legs.compactMap { turn in
            if case .image(let capture) = turn.kind { return capture }
            return nil
        }
    }

    /// Groups image turns into replay units: a multi-ground group's legs (consecutive turns sharing a
    /// `compositeGroupID`) form ONE unit; standalone images are their own unit. Order preserved, so
    /// `maxImagePayloads` budgets whole questions and never replays half a group.
    private func imagePayloadUnits(_ imageTurns: [ChatTurn]) -> [[ChatTurn]] {
        var units: [[ChatTurn]] = []
        var previousGroup: UUID?
        for turn in imageTurns {
            if let group = turn.compositeGroupID, group == previousGroup, !units.isEmpty {
                units[units.count - 1].append(turn)
            } else {
                units.append([turn])
            }
            previousGroup = turn.compositeGroupID
        }
        return units
    }

    /// Maps the display conversation to the model's message list: each image unit becomes one
    /// grounded user message. A multi-ground unit (e.g. screen + camera, or any N grounds) folds all
    /// its legs into a single message carrying every leg's image, in order; standalone images are
    /// byte-identical to before. Only the latest `policy.maxImagePayloads` units ride as base64
    /// payloads; older ones keep text grounding.
    private func inferenceMessages(
        from conversation: [ChatTurn],
        webLookup: WebLookupSnapshot? = nil,
        policy: InferenceReplayPolicy = .inference,
        imageBase64ByTurnID: [Int: String] = [:]
    ) -> [InferenceMessage] {
        let units = imagePayloadUnits(conversation.filter(\.isImage))
        let replayImageIDs = Set(units.suffix(policy.maxImagePayloads).flatMap { $0.map(\.id) })
        let lastUnitIDs = Set(units.last?.map(\.id) ?? [])
        // Per-leg unit position (0-based among image units) and the representative ("first") leg of
        // each unit — the one we emit; the other legs of a composite were already folded into it.
        var unitIndexByID: [Int: Int] = [:]
        var firstLegIDs = Set<Int>()
        for (index, unit) in units.enumerated() {
            let ordered = unit.sorted { $0.id < $1.id }
            if let first = ordered.first { firstLegIDs.insert(first.id) }
            for leg in unit { unitIndexByID[leg.id] = index }
        }

        var messages: [InferenceMessage] = []
        for turn in conversation {
            switch turn.kind {
            case .image(let capture):
                guard firstLegIDs.contains(turn.id) else { continue } // folded composite leg, already emitted
                let unitIndex = unitIndexByID[turn.id] ?? 0
                let assembly = promptAssembly(continuingSession: unitIndex > 0)
                let lookup = lastUnitIDs.contains(turn.id) ? webLookup : nil
                let unit = units[unitIndex].sorted { $0.id < $1.id }

                if unit.count > 1 {
                    // Multi-ground turn: project each leg into a MediaPayload and fold them into one
                    // message, named in order. Replay is group-atomic, so the images ride only when
                    // the whole unit is in the replay window (otherwise the legs keep text grounding).
                    let includeImages = unit.allSatisfy { replayImageIDs.contains($0.id) }
                    let payloads: [MediaPayload] = unit.compactMap { leg in
                        guard case .image(let c) = leg.kind else { return nil }
                        // A transcript leg (e.g. system audio) carries no image — its text is folded in
                        // by the prompt builder, so it never gets a base64 payload even inside the budget.
                        let kind = MediaPayload.Kind.resolved(for: c.ground)
                        let base64 = (kind == .image && includeImages)
                            ? (imageBase64ByTurnID[leg.id] ?? c.screenshotBase64) : nil
                        return MediaPayload(capture: c, kind: kind, imageBase64: base64)
                    }
                    messages.append(InferenceMessage(
                        role: .user,
                        text: PromptBuilder.multiGroundUserMessage(
                            payloads: payloads, assembly: assembly, webLookup: lookup
                        ),
                        imagesBase64: payloads.compactMap(\.imageBase64)
                    ))
                } else {
                    let includeImage = replayImageIDs.contains(turn.id)
                    messages.append(InferenceMessage(
                        role: .user,
                        text: PromptBuilder.captureUserMessage(
                            capture: capture,
                            assembly: assembly,
                            webLookup: lookup,
                            question: turn.question   // a live-promoted frame folds its note into this message
                        ),
                        imageBase64: includeImage ? (imageBase64ByTurnID[turn.id] ?? capture.screenshotBase64) : nil
                    ))
                }
            case .user(let text):
                messages.append(InferenceMessage(
                    role: .user,
                    text: PromptBuilder.followUpUserMessage(
                        question: text,
                        assembly: promptAssembly(continuingSession: false)
                    )
                ))
            case .assistant(let text):
                messages.append(InferenceMessage(role: .assistant, text: text))
            }
        }
        return messages
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
            profileTemplate: session.activeProfileTemplate,
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

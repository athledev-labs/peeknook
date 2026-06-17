// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The non-blocking follow-up suggestion pass: a separate, schema-constrained call that proposes the
/// dynamic action pills for the answer just shown, then attaches its token cost to the answer turn.
/// Owned by ``InferenceCoordinator``; weakly holds the orchestrator so it can read modules and the
/// conversation and write back the pills/usage without retaining the session.
@MainActor
final class SuggestionCoordinator {
    private weak var session: SessionOrchestrator?

    init(session: SessionOrchestrator) {
        self.session = session
    }

    /// Generates the dynamic action pills for the answer just shown. Controlled by the
    /// `suggestFollowUps` module (global setting + the turn profile's override), it's a separate,
    /// non-blocking call, so quick mode (which is about answer terseness) doesn't disable it.
    /// Applies only if the same answer is on screen.
    func fetchSuggestions(gatedBy turnProfile: GroundProfile) {
        guard let session else { return }
        session.lifecycle.suggestionTask?.cancel()
        session.suggestedFollowUps = []
        guard session.moduleEnabled(.suggestFollowUps, for: turnProfile) else {
            session.isFetchingSuggestions = false
            return
        }
        session.isFetchingSuggestions = true
        let builder = InferenceMessageBuilder(
            quickMode: session.settings.quickMode,
            sessionBrief: session.sessionBrief.nilIfEmpty
        )
        // The appendix rides symmetrically; both engines' suggestion pass uses the static
        // follow-up prompt today, so pills stay persona-blind in v1 (recorded seam).
        let request = InferenceRequest(
            mode: session.settings.mode,
            agentSystemAppendix: session.activeAgentAppendix,
            profileTemplate: session.activeProfileTemplate,
            messages: builder.inferenceMessages(from: session.conversation, policy: .suggestions),
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
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct InferenceRequest: Sendable, Equatable {
    public var mode: PracticeMode
    /// Full user/assistant sequence for this turn (oldest first), images attached to the user
    /// messages that introduced them. The engine prepends the system prompt.
    public var messages: [InferenceMessage]
    public var model: String
    public var ollamaBaseURL: String
    public var quickMode: Bool

    public init(
        mode: PracticeMode,
        messages: [InferenceMessage],
        model: String,
        ollamaBaseURL: String,
        quickMode: Bool = false
    ) {
        self.mode = mode
        self.messages = messages
        self.model = model
        self.ollamaBaseURL = ollamaBaseURL
        self.quickMode = quickMode
    }
}

/// Per-inference telemetry from the engine (Ollama reports these on the final chunk).
public struct InferenceStats: Sendable, Equatable, Codable {
    public var promptTokens: Int
    public var responseTokens: Int
    public var generationSeconds: Double

    public init(promptTokens: Int = 0, responseTokens: Int = 0, generationSeconds: Double = 0) {
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
        self.generationSeconds = generationSeconds
    }
}

public enum InferenceEvent: Sendable, Equatable {
    case token(String)
    case completed(InferenceStats?)
}

public enum InferenceHealth: Sendable, Equatable {
    case ready
    case unavailable(String)
}

/// Streaming inference boundary, Ollama and test mocks conform here.
public protocol InferenceEngine: Sendable {
    func health(baseURL: String, model: String) async -> InferenceHealth
    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error>
    /// Schema-constrained generation of next-question suggestions for the current conversation.
    /// Best-effort: empty suggestions on failure so the UI simply shows no pills.
    func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult
    /// Proactively load the model into memory (resets `keep_alive`) so the next real capture
    /// isn't the one that pays the cold-start cost.
    func warmUp(model: String, baseURL: String) async
    /// The model's context window in tokens (for the chat's context-usage meter), or nil if
    /// unknown. Best-effort.
    func contextLength(model: String, baseURL: String) async -> Int?
    /// The model's declared capabilities (e.g. "vision", "completion", "tools"), or nil if the
    /// model isn't installed / can't be inspected. Best-effort; used to warn when a chosen model
    /// can't see the captured screenshot.
    func capabilities(model: String, baseURL: String) async -> [String]?
}

public extension InferenceEngine {
    func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult {
        FollowUpGenerationResult(suggestions: [])
    }
    func warmUp(model: String, baseURL: String) async {}
    func contextLength(model: String, baseURL: String) async -> Int? { nil }
    func capabilities(model: String, baseURL: String) async -> [String]? { nil }

    /// Whether the model can read images. `nil` when unknown (not installed / older Ollama that
    /// omits the capabilities list) so callers can stay silent instead of warning incorrectly.
    func supportsVision(model: String, baseURL: String) async -> Bool? {
        guard let caps = await capabilities(model: model, baseURL: baseURL) else { return nil }
        return caps.contains { $0.caseInsensitiveCompare("vision") == .orderedSame }
    }
}

// MARK: - Test-only mock (not used in the app target wiring)

public struct MockInferenceEngine: InferenceEngine, Sendable {
    public var tokens: [String]
    public var delayNanoseconds: UInt64
    public var completionStats: InferenceStats?

    public init(
        tokens: [String] = ["안녕", " ", "informal ", "greeting."],
        delayNanoseconds: UInt64 = 40_000_000,
        completionStats: InferenceStats? = nil
    ) {
        self.tokens = tokens
        self.delayNanoseconds = delayNanoseconds
        self.completionStats = completionStats
    }

    public func health(baseURL: String, model: String) async -> InferenceHealth { .ready }

    public func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        _ = request
        return AsyncThrowingStream { continuation in
            let task = Task {
                for token in tokens {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                continuation.yield(.completed(completionStats))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

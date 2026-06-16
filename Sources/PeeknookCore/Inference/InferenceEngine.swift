// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct InferenceRequest: Sendable, Equatable {
    public var mode: PracticeMode
    /// Optional system-prompt appendix for future user-defined agents.
    public var agentSystemAppendix: String?
    /// Optional per-profile prompt template, folded into the system prompt as its own fenced section
    /// (distinct from `agentSystemAppendix`). Nil = no template (requests stay byte-identical).
    public var profileTemplate: String?
    /// Full user/assistant sequence for this turn (oldest first), images attached to the user
    /// messages that introduced them. The engine prepends the system prompt.
    public var messages: [InferenceMessage]
    public var model: String
    public var endpoint: InferenceEndpoint
    public var quickMode: Bool

    public init(
        mode: PracticeMode,
        agentSystemAppendix: String? = nil,
        profileTemplate: String? = nil,
        messages: [InferenceMessage],
        model: String,
        endpoint: InferenceEndpoint,
        quickMode: Bool = false
    ) {
        self.mode = mode
        self.agentSystemAppendix = agentSystemAppendix
        self.profileTemplate = profileTemplate
        self.messages = messages
        self.model = model
        self.endpoint = endpoint
        self.quickMode = quickMode
    }

    /// Convenience for call sites that still have settings fields.
    public init(
        mode: PracticeMode,
        agentSystemAppendix: String? = nil,
        profileTemplate: String? = nil,
        messages: [InferenceMessage],
        model: String,
        ollamaBaseURL: String,
        quickMode: Bool = false,
        acceptInsecureRemoteOllama: Bool = false
    ) {
        self.init(
            mode: mode,
            agentSystemAppendix: agentSystemAppendix,
            profileTemplate: profileTemplate,
            messages: messages,
            model: model,
            endpoint: .ollama(baseURL: ollamaBaseURL, acceptInsecureRemote: acceptInsecureRemoteOllama),
            quickMode: quickMode
        )
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
    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth
    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error>
    /// Schema-constrained generation of next-question suggestions for the current conversation.
    /// Best-effort: empty suggestions on failure so the UI simply shows no pills.
    func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult
    /// Proactively load the model into memory (resets `keep_alive`) so the next real capture
    /// isn't the one that pays the cold-start cost. Returns whether the model was actually loaded,
    /// so callers don't record a warm model after a failed warm-up.
    @discardableResult
    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool
    /// The model's context window in tokens (for the chat's context-usage meter), or nil if
    /// unknown. Best-effort.
    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int?
    /// The model's declared capabilities (e.g. "vision", "completion", "tools"), or nil if the
    /// model isn't installed / can't be inspected. Best-effort; used to warn when a chosen model
    /// can't see the captured screenshot.
    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]?
}

public extension InferenceEngine {
    func health(baseURL: String, model: String) async -> InferenceHealth {
        await health(baseURL: baseURL, model: model, acceptInsecureRemote: false)
    }

    func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult {
        FollowUpGenerationResult(suggestions: [])
    }
    @discardableResult
    func warmUp(model: String, baseURL: String) async -> Bool {
        await warmUp(model: model, baseURL: baseURL, acceptInsecureRemote: false)
    }
    func contextLength(model: String, baseURL: String) async -> Int? { nil }
    func capabilities(model: String, baseURL: String) async -> [String]? { nil }

    /// Whether the model can read images. `nil` when unknown (not installed / older Ollama that
    /// omits the capabilities list) so callers can stay silent instead of warning incorrectly.
    func supportsVision(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool? {
        guard let caps = await capabilities(model: model, baseURL: baseURL, acceptInsecureRemote: acceptInsecureRemote) else { return nil }
        return caps.contains { $0.caseInsensitiveCompare("vision") == .orderedSame }
    }

    func supportsVision(model: String, baseURL: String) async -> Bool? {
        await supportsVision(model: model, baseURL: baseURL, acceptInsecureRemote: false)
    }
}

// MARK: - Endpoint-typed variants
//
// Typed siblings of the `baseURL: String` requirements above — pure adapters that decompose
// `endpoint.connection`, so every conformer inherits them. They live ALONGSIDE the string
// variants (which existing call sites keep using); neither replaces the other.

public extension InferenceEngine {
    func health(endpoint: InferenceEndpoint, model: String) async -> InferenceHealth {
        let connection = endpoint.connection
        return await health(
            baseURL: connection.baseURL,
            model: model,
            acceptInsecureRemote: connection.acceptInsecureRemote
        )
    }

    @discardableResult
    func warmUp(model: String, endpoint: InferenceEndpoint) async -> Bool {
        let connection = endpoint.connection
        return await warmUp(
            model: model,
            baseURL: connection.baseURL,
            acceptInsecureRemote: connection.acceptInsecureRemote
        )
    }

    func contextLength(model: String, endpoint: InferenceEndpoint) async -> Int? {
        let connection = endpoint.connection
        return await contextLength(
            model: model,
            baseURL: connection.baseURL,
            acceptInsecureRemote: connection.acceptInsecureRemote
        )
    }

    func capabilities(model: String, endpoint: InferenceEndpoint) async -> [String]? {
        let connection = endpoint.connection
        return await capabilities(
            model: model,
            baseURL: connection.baseURL,
            acceptInsecureRemote: connection.acceptInsecureRemote
        )
    }

    func supportsVision(model: String, endpoint: InferenceEndpoint) async -> Bool? {
        let connection = endpoint.connection
        return await supportsVision(
            model: model,
            baseURL: connection.baseURL,
            acceptInsecureRemote: connection.acceptInsecureRemote
        )
    }
}

// MARK: - Test-only mock (not used in the app target wiring)

public struct MockInferenceEngine: InferenceEngine, Sendable {
    public var tokens: [String]
    public var delayNanoseconds: UInt64
    public var completionStats: InferenceStats?
    /// When `false`, simulates a truncated Ollama stream that never yields `.completed`.
    public var sendsCompletion: Bool
    /// Capabilities returned by `capabilities(...)` / `supportsVision(...)`. `nil` (default)
    /// simulates an uninstalled model or an older runtime that omits the list — vision "unknown".
    public var declaredCapabilities: [String]?

    public init(
        tokens: [String] = ["hello", " ", "from ", "the mock."],
        delayNanoseconds: UInt64 = 0,
        completionStats: InferenceStats? = nil,
        sendsCompletion: Bool = true,
        declaredCapabilities: [String]? = nil
    ) {
        self.tokens = tokens
        self.delayNanoseconds = delayNanoseconds
        self.completionStats = completionStats
        self.sendsCompletion = sendsCompletion
        self.declaredCapabilities = declaredCapabilities
    }

    public func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }

    public func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool { true }

    public func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { nil }

    public func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? { declaredCapabilities }

    public func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        _ = request
        return AsyncThrowingStream { continuation in
            let task = Task {
                for token in tokens {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                if sendsCompletion {
                    continuation.yield(.completed(completionStats))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

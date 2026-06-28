// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Inference against a local OpenAI-compatible server (LM Studio, vLLM class) over
/// `/v1/chat/completions` SSE. Differences from the Ollama engine, all deliberate:
/// - No `think` field and no think-retry — there is no reasoning toggle on this API.
/// - No `keep_alive` — the server manages its own model residency; warm-up is a 1-token completion.
/// - `capabilities`/`contextLength` are always nil: `/v1/models` reports no metadata, so the vision
///   gate degrades to `.unknown` (never false-blocks) and the context meter stays quiet.
/// The API key is resolved from the Keychain at request time via the injected resolver; keyless is
/// the normal local-server path (no Authorization header at all).
public struct OpenAICompatibleInferenceEngine: InferenceEngine, Sendable {
    public var session: URLSession
    private let client: OpenAICompatibleHTTPClient
    private let resolveAPIKey: @Sendable (CredentialRef) -> String?
    /// Ref used by the string-`baseURL` protocol requirements, which carry no endpoint (and thus
    /// no ref). The app-wide primary slot until profiles bind per-profile credentials.
    private let defaultKeyRef = CredentialRef.openAICompatiblePrimary

    public init(
        session: URLSession = .shared,
        resolveAPIKey: @escaping @Sendable (CredentialRef) -> String? = { _ in nil }
    ) {
        self.session = session
        self.client = OpenAICompatibleHTTPClient(session: session)
        self.resolveAPIKey = resolveAPIKey
    }

    /// The string-`baseURL` probe path (health / warm-up / served-models) through the same
    /// ``EndpointURLPolicy`` gate the per-turn path uses via ``InferenceEndpoint/resolvedBaseURL()``.
    /// These protocol methods carry a raw URL, not a built ``InferenceEndpoint``, so they gate here.
    private func resolveBaseURL(_ string: String, acceptInsecureRemote: Bool) throws -> URL {
        try EndpointURLPolicy.resolveOrThrow(string, acceptInsecureRemote: acceptInsecureRemote)
    }

    // MARK: - Health

    public func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth {
        do {
            let base = try resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote)
            let served = try await client.modelIDs(base: base, apiKey: resolveAPIKey(defaultKeyRef))
            guard !ModelTag.normalized(model).isEmpty else {
                return .unavailable("Choose a model from the server's list in Settings.")
            }
            guard OllamaSetupClient.matchesModel(installedNames: served, wanted: model) else {
                return .unavailable("“\(model)” isn't loaded on the inference server.")
            }
            return .ready
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Answer stream

    public func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let base = try request.endpoint.resolvedBaseURL(expecting: .openAICompatible)
                    try await streamChat(base: base, request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamChat(
        base: URL,
        request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) async throws {
        let messages = Self.wireMessages(
            from: request,
            systemPrompt: PromptBuilder.systemPrompt(agentAppendix: request.agentSystemAppendix, profileTemplate: request.profileTemplate)
        )
        #if DEBUG
        let imageCount = request.messages.reduce(0) { $0 + $1.imagesBase64.count }
        InferenceDebugLog.recordImagePayloadCount(imageCount, model: request.model)
        #endif

        let bytes = try await client.chatStream(
            base: base,
            model: request.model,
            messages: messages,
            quickMode: request.quickMode,
            apiKey: apiKey(for: request.endpoint)
        )

        var stats: InferenceStats?
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                continuation.yield(.completed(stats))
                continuation.finish()
                return
            }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OpenAIChatChunk.self, from: data) else { continue }
            if let piece = chunk.choices?.first?.delta?.content, !piece.isEmpty {
                continuation.yield(.token(piece))
            }
            if let usage = chunk.usage {
                stats = InferenceStats(
                    promptTokens: usage.promptTokens ?? 0,
                    responseTokens: usage.completionTokens ?? 0,
                    generationSeconds: 0 // the API reports no timing; 0 is honest, not a guess
                )
            }
        }
        // Stream ended without [DONE] — complete with whatever stats arrived (parity with Ollama).
        continuation.yield(.completed(stats))
        continuation.finish()
    }

    // MARK: - Follow-up suggestions (schema-constrained, non-streaming)

    public func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult {
        do {
            let base = try request.endpoint.resolvedBaseURL(expecting: .openAICompatible)
            var messages = Self.wireMessages(
                from: request, systemPrompt: PromptBuilder.followUpSystemPrompt
            )
            messages.append(
                OpenAIChatMessage(role: "user", text: PromptBuilder.followUpUserPrompt)
            )

            func fetch(responseFormat: [String: Any]) async throws -> Data {
                try await client.chatData(
                    base: base,
                    model: request.model,
                    messages: messages,
                    maxTokens: 120,
                    temperature: 0.4,
                    responseFormat: responseFormat,
                    apiKey: apiKey(for: request.endpoint),
                    timeout: 30
                )
            }

            // Grammar-constrained first; some servers only support the looser json_object mode.
            let schemaFormat: [String: Any] = [
                "type": "json_schema",
                "json_schema": ["name": "follow_up_suggestions", "schema": PromptBuilder.followUpSchema]
            ]
            let data: Data
            do {
                data = try await fetch(responseFormat: schemaFormat)
            } catch InferenceError.http(let status, _) where status == 400 {
                data = try await fetch(responseFormat: ["type": "json_object"])
            }
            return FollowUpGenerationResult(
                suggestions: Self.parseSuggestions(from: data),
                stats: Self.parseChatStats(from: data)
            )
        } catch {
            return FollowUpGenerationResult(suggestions: [])
        }
    }

    /// Non-streaming body: `{ "choices": [ { "message": { "content": "<json>" } } ], "usage": … }`.
    static func parseSuggestions(from data: Data) -> [String] {
        guard let chunk = try? JSONDecoder().decode(OpenAIChatChunk.self, from: data),
              let content = chunk.choices?.first?.message?.content,
              let inner = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
              let suggestions = parsed["suggestions"] as? [String]
        else { return [] }
        let cleaned = suggestions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(cleaned.prefix(3))
    }

    static func parseChatStats(from data: Data) -> InferenceStats? {
        guard let chunk = try? JSONDecoder().decode(OpenAIChatChunk.self, from: data),
              let usage = chunk.usage else { return nil }
        let prompt = usage.promptTokens ?? 0
        let response = usage.completionTokens ?? 0
        guard prompt > 0 || response > 0 else { return nil }
        return InferenceStats(promptTokens: prompt, responseTokens: response, generationSeconds: 0)
    }

    // MARK: - Warm-up

    @discardableResult
    public func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool {
        guard let base = try? resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote) else { return false }
        do {
            _ = try await client.chatData(
                base: base,
                model: model,
                messages: [OpenAIChatMessage(role: "user", text: "ok")],
                maxTokens: 1,
                temperature: nil,
                responseFormat: nil,
                apiKey: resolveAPIKey(defaultKeyRef)
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Served models (Settings picker)

    /// Model ids the server lists on `/v1/models`; empty on any failure — the Settings picker
    /// shows its "no models found" hint instead of an error.
    public func listServedModels(baseURL: String, acceptInsecureRemote: Bool) async -> [String] {
        guard let base = try? resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote) else { return [] }
        return (try? await client.modelIDs(base: base, apiKey: resolveAPIKey(defaultKeyRef))) ?? []
    }

    // MARK: - Capability probes (honestly unknown)

    /// `/v1/models` reports no context metadata — nil keeps the context meter quiet, never wrong.
    public func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? {
        nil
    }

    /// `/v1/models` reports no capability metadata — nil makes the vision gate degrade to
    /// `.unknown`, which allows capture (a verifiable "textOnly" must come from a real probe).
    public func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? {
        nil
    }

    /// `/v1` exposes no residency endpoint — nil keeps the warm-copy gate honestly "unknown" here, so
    /// it falls back to the in-session timer instead of guessing the server's model state.
    public func isModelResident(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool? {
        nil
    }

    // MARK: - Message mapping

    /// System prompt first, then the turn sequence; each turn's image rides its own message in
    /// content-array form (see `OpenAIChatMessage.contentValue`).
    static func wireMessages(from request: InferenceRequest, systemPrompt: String) -> [OpenAIChatMessage] {
        var messages = [OpenAIChatMessage(role: "system", text: systemPrompt)]
        for turn in request.messages {
            messages.append(OpenAIChatMessage(
                role: turn.role.rawValue,
                text: turn.text,
                imagesBase64: turn.imagesBase64
            ))
        }
        return messages
    }

    private func apiKey(for endpoint: InferenceEndpoint) -> String? {
        switch endpoint {
        case .ollama:
            return nil
        case .openAICompatible(_, let apiKeyRef, _):
            return resolveAPIKey(apiKeyRef)
        }
    }
}

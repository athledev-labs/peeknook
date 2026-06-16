// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct OllamaInferenceEngine: InferenceEngine, Sendable {
    public var session: URLSession
    private let client: OllamaHTTPClient
    /// Shared health-probe coalescer (nil = probe the network directly, the original behavior). Lets
    /// `health`/`ensureModel` `/api/version` + `/api/tags` checks coalesce with the setup refresh that
    /// fires alongside them on a Settings open.
    private let probeCache: OllamaProbeCache?

    public init(session: URLSession = .shared, probeCache: OllamaProbeCache? = nil) {
        self.session = session
        self.client = OllamaHTTPClient(session: session)
        self.probeCache = probeCache
    }

    public func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth {
        do {
            let base = try resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote)
            _ = try await fetchVersion(baseURL: base)
            try await ensureModel(baseURL: base, model: model)
            return .ready
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let base = try resolveEndpoint(request.endpoint)
                    try await ensureModel(baseURL: base, model: request.model)
                    try await streamChat(
                        baseURL: base,
                        request: request,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Ollama HTTP

    private func resolveBaseURL(_ string: String, acceptInsecureRemote: Bool) throws -> URL {
        try EndpointURLPolicy.resolveOrThrow(string, acceptInsecureRemote: acceptInsecureRemote)
    }

    private func resolveEndpoint(_ endpoint: InferenceEndpoint) throws -> URL {
        switch endpoint {
        case .ollama(let baseURL, let acceptInsecureRemote):
            return try resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote)
        case .openAICompatible:
            // Defense-in-depth: the backend registry routes OpenAI-compatible endpoints to their
            // own engine, so reaching this arm means a mis-route — fail loud, not "Invalid URL".
            assertionFailure("OllamaInferenceEngine received an OpenAI-compatible endpoint")
            throw InferenceError.invalidBaseURL
        }
    }

    private func fetchVersion(baseURL: URL) async throws {
        let session = self.session
        _ = try await OllamaProbeCache.resolve(
            probeCache, baseURL: baseURL, path: "api/version", ttl: OllamaProbeCache.healthTTL
        ) {
            let url = baseURL.appendingPathComponent("api/version")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 4
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw InferenceError.ollamaUnreachable(OllamaUnreachableCopy.notRunning)
            }
            return data
        }
    }

    private func ensureModel(baseURL: URL, model: String) async throws {
        let session = self.session
        let data = try await OllamaProbeCache.resolve(
            probeCache, baseURL: baseURL, path: "api/tags", ttl: OllamaProbeCache.healthTTL
        ) {
            let url = baseURL.appendingPathComponent("api/tags")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 8
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw InferenceError.ollamaUnreachable("Could not list Ollama models.")
            }
            return data
        }
        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        guard OllamaSetupClient.matchesModel(installedNames: tags.models.map(\.name), wanted: model) else {
            throw InferenceError.modelMissing(
                model,
                hint: "Run: ollama pull \(model)"
            )
        }
    }

    private func streamChat(
        baseURL: URL,
        request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) async throws {
        // Each user message carries the screenshot it introduced; Ollama keeps earlier images in
        // context, so a chat can span several captures.
        var messages: [OllamaChatMessage] = [
            OllamaChatMessage(role: "system", content: PromptBuilder.systemPrompt(agentAppendix: request.agentSystemAppendix, profileTemplate: request.profileTemplate), images: nil)
        ]
        for turn in request.messages {
            messages.append(OllamaChatMessage(role: turn.role.rawValue, content: turn.text, images: turn.imagesBase64.isEmpty ? nil : turn.imagesBase64))
        }
        #if DEBUG
        let imageCount = request.messages.reduce(0) { $0 + $1.imagesBase64.count }
        InferenceDebugLog.recordImagePayloadCount(imageCount, model: request.model)
        #endif

        // The client applies `think:false` (with a one-shot retry without `think` on a 400 that
        // mentions it) and surfaces Ollama's real error body on other failures.
        let bytes = try await client.chatStream(
            base: baseURL,
            model: request.model,
            messages: messages,
            quickMode: request.quickMode,
            // Keep the model warm so the next capture skips cold-start.
            keepAlive: "10m"
        )

        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: data)
            if let piece = chunk.message?.content, !piece.isEmpty {
                continuation.yield(.token(piece))
            }
            if chunk.done == true {
                let stats = InferenceStats(
                    promptTokens: chunk.promptEvalCount ?? 0,
                    responseTokens: chunk.evalCount ?? 0,
                    generationSeconds: Double(chunk.evalDuration ?? 0) / 1_000_000_000
                )
                continuation.yield(.completed(stats))
                continuation.finish()
                return
            }
        }
        continuation.yield(.completed(nil))
        continuation.finish()
    }

    // MARK: - Follow-up suggestions (schema-constrained, non-streaming)

    public func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult {
        do {
            let base = try resolveEndpoint(request.endpoint)

            // Replay the same conversation (with its images), then ask for suggestions,
            // constrained to the JSON schema.
            var messages: [OllamaChatMessage] = [
                OllamaChatMessage(role: "system", content: PromptBuilder.followUpSystemPrompt)
            ]
            for turn in request.messages {
                messages.append(OllamaChatMessage(role: turn.role.rawValue, content: turn.text, images: turn.imagesBase64.isEmpty ? nil : turn.imagesBase64))
            }
            messages.append(OllamaChatMessage(role: "user", content: PromptBuilder.followUpUserPrompt))

            // The client applies `think:false` + one-shot think-retry (see streamChat) and surfaces
            // Ollama errors; we stay best-effort and swallow any throw below.
            let data = try await client.chatData(
                base: base,
                model: request.model,
                messages: messages,
                stream: false,
                keepAlive: "10m",
                options: ["num_predict": 120, "temperature": 0.4],
                format: PromptBuilder.followUpSchema,
                timeout: 30 // parity with the original follow-up pass; the answer stream uses 120s
            )
            let suggestions = Self.parseSuggestions(from: data)
            let stats = Self.parseChatStats(from: data)
            return FollowUpGenerationResult(suggestions: suggestions, stats: stats)
        } catch {
            return FollowUpGenerationResult(suggestions: [])
        }
    }

    /// Token counts from a non-streaming `/api/chat` response (same fields as the final stream chunk).
    static func parseChatStats(from data: Data) -> InferenceStats? {
        guard let chunk = try? JSONDecoder().decode(OllamaChatChunk.self, from: data),
              chunk.done == true || chunk.promptEvalCount != nil
        else { return nil }
        let prompt = chunk.promptEvalCount ?? 0
        let response = chunk.evalCount ?? 0
        guard prompt > 0 || response > 0 else { return nil }
        return InferenceStats(
            promptTokens: prompt,
            responseTokens: response,
            generationSeconds: Double(chunk.evalDuration ?? 0) / 1_000_000_000
        )
    }

    /// Non-stream `/api/chat` returns `{ "message": { "content": "<json>" } }`; the content is the
    /// schema-constrained JSON object. Tolerant of extra fields.
    static func parseSuggestions(from data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String,
              let inner = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
              let suggestions = parsed["suggestions"] as? [String]
        else { return [] }
        let cleaned = suggestions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(cleaned.prefix(3))
    }

    // MARK: - Context window

    public func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? {
        guard let base = try? resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote) else { return nil }
        let url = base.appendingPathComponent("api/show")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.parseContextLength(from: data)
    }

    // MARK: - Capabilities

    public func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? {
        guard let base = try? resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote) else { return nil }
        let url = base.appendingPathComponent("api/show")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.parseCapabilities(from: data)
    }

    /// `/api/show` returns a top-level `"capabilities": ["completion", "vision", ...]` array on
    /// recent Ollama. Returns nil when absent so callers treat support as unknown, not "no vision".
    static func parseCapabilities(from data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caps = root["capabilities"] as? [String] else { return nil }
        return caps
    }

    /// `/api/show` returns `{ "model_info": { "<arch>.context_length": N, ... } }`; the key is
    /// architecture-prefixed (e.g. `gemma3.context_length`), so match by suffix.
    static func parseContextLength(from data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["model_info"] as? [String: Any] else { return nil }
        for (key, value) in info where key == "context_length" || key.hasSuffix(".context_length") {
            if let n = value as? Int { return n }
            if let d = value as? Double { return Int(d) }
        }
        return nil
    }

    // MARK: - Warm-up

    @discardableResult
    public func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool {
        guard let base = try? resolveBaseURL(baseURL, acceptInsecureRemote: acceptInsecureRemote) else { return false }
        // The client applies `think:false` with a one-shot retry without `think` on a 400 that
        // mentions it, so a non-reasoning model still warms. A successful (non-throwing) call means
        // the model loaded; any thrown error is a failed warm-up the caller must not treat as warm.
        do {
            _ = try await client.chatData(
                base: base,
                model: model,
                messages: [OllamaChatMessage(role: "user", content: "ok")],
                stream: false,
                keepAlive: "10m",
                options: ["num_predict": 1],
                format: nil
            )
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Errors & DTOs

public enum InferenceError: Error, Sendable, LocalizedError {
    case invalidBaseURL
    case insecureRemoteHTTP
    case ollamaUnreachable(String)
    case modelMissing(String, hint: String)
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            // Thrown by EndpointURLPolicy for every backend — keep the copy backend-neutral.
            "Invalid inference server URL in Settings."
        case .insecureRemoteHTTP:
            "A remote server must use HTTPS, or enable “Allow insecure HTTP” in Settings → Answer model."
        case .ollamaUnreachable(let msg):
            msg
        case .modelMissing(let model, let hint):
            "Model “\(model)” is not installed. \(hint)"
        case .http(_, let message):
            message
        }
    }
}

private struct OllamaChatChunk: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let content: String?
    }
    let message: Message?
    let done: Bool?
    let promptEvalCount: Int?
    let evalCount: Int?
    let evalDuration: Int? // nanoseconds

    enum CodingKeys: String, CodingKey {
        case message, done
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
    }
}

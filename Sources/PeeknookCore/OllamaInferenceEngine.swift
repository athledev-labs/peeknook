// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct OllamaInferenceEngine: InferenceEngine, Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func health(baseURL: String, model: String) async -> InferenceHealth {
        do {
            let base = try await resolveBaseURL(baseURL)
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
                    let base = try await resolveBaseURL(request.ollamaBaseURL)
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

    private func resolveBaseURL(_ string: String) async throws -> URL {
        guard let url = URL(string: string), url.scheme != nil else {
            throw InferenceError.invalidBaseURL
        }
        return url
    }

    private func fetchVersion(baseURL: URL) async throws {
        let url = baseURL.appendingPathComponent("api/version")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 4
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InferenceError.ollamaUnreachable(
                "Start Ollama: run `ollama serve` in Terminal."
            )
        }
    }

    private func ensureModel(baseURL: URL, model: String) async throws {
        let url = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InferenceError.ollamaUnreachable("Could not list Ollama models.")
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
        let url = baseURL.appendingPathComponent("api/chat")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        // Each user message carries the screenshot it introduced; Ollama keeps earlier images in
        // context, so a chat can span several captures.
        var messages: [OllamaChatRequest.Message] = [
            .init(role: "system", content: PromptBuilder.systemPrompt(for: request.mode), images: nil)
        ]
        for turn in request.messages {
            messages.append(.init(role: turn.role.rawValue, content: turn.text, images: turn.imageBase64.map { [$0] }))
        }
        func makeBody(think: Bool?) -> OllamaChatRequest {
            OllamaChatRequest(
                model: request.model,
                messages: messages,
                stream: true,
                // Keep the model warm so the next capture skips cold-start; cap output in quick mode.
                keepAlive: "10m",
                think: think,
                options: request.quickMode ? OllamaChatRequest.Options(numPredict: 256) : nil
            )
        }
        func send(_ body: OllamaChatRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
            var attempt = req
            attempt.httpBody = try JSONEncoder().encode(body)
            let (bytes, response) = try await session.bytes(for: attempt)
            guard let http = response as? HTTPURLResponse else {
                throw InferenceError.ollamaUnreachable("No response from Ollama.")
            }
            return (bytes, http)
        }

        // Gemma 4 reasons by default and streams empty `content` until thinking ends (blank answers,
        // worst in quick mode) — a notch HUD wants the direct answer, so disable chain-of-thought.
        // Not every model supports `think`; if Ollama 400s on it, retry once without it so swapping
        // to a non-reasoning model still works.
        var (bytes, http) = try await send(makeBody(think: false))
        if http.statusCode == 400 {
            let detail = await Self.readErrorBody(bytes)
            if (detail ?? "").lowercased().contains("think") {
                (bytes, http) = try await send(makeBody(think: nil))
            } else {
                throw InferenceError.http(status: 400, message: Self.friendlyChatFailure(status: 400, ollamaError: detail))
            }
        }
        guard http.statusCode == 200 else {
            // Surface Ollama's actual error body — a generic "check the model" hint hides
            // real failures like a missing llama-server runner.
            let detail = await Self.readErrorBody(bytes)
            throw InferenceError.http(
                status: http.statusCode,
                message: Self.friendlyChatFailure(status: http.statusCode, ollamaError: detail)
            )
        }

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
            let base = try await resolveBaseURL(request.ollamaBaseURL)
            let url = base.appendingPathComponent("api/chat")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 30

            // Replay the same conversation (with its images), then ask for suggestions,
            // constrained to the JSON schema.
            var messages: [[String: Any]] = [
                ["role": "system", "content": PromptBuilder.followUpSystemPrompt]
            ]
            for turn in request.messages {
                var msg: [String: Any] = ["role": turn.role.rawValue, "content": turn.text]
                if let image = turn.imageBase64 { msg["images"] = [image] }
                messages.append(msg)
            }
            messages.append(["role": "user", "content": PromptBuilder.followUpUserPrompt])

            let body: [String: Any] = [
                "model": request.model,
                "messages": messages,
                "stream": false,
                "keep_alive": "10m",
                "think": false, // direct JSON, not chain-of-thought (see streamChat)
                "format": PromptBuilder.followUpSchema,
                "options": ["num_predict": 120, "temperature": 0.4]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return FollowUpGenerationResult(suggestions: [])
            }
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

    public func contextLength(model: String, baseURL: String) async -> Int? {
        guard let base = try? await resolveBaseURL(baseURL) else { return nil }
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

    public func capabilities(model: String, baseURL: String) async -> [String]? {
        guard let base = try? await resolveBaseURL(baseURL) else { return nil }
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

    public func warmUp(model: String, baseURL: String) async {
        guard let base = try? await resolveBaseURL(baseURL) else { return }
        let url = base.appendingPathComponent("api/chat")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "ok"]],
            "stream": false,
            "keep_alive": "10m",
            "think": false,
            "options": ["num_predict": 1]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: req) // fire-and-forget; only side effect is a loaded model
    }

    // MARK: - Error surfacing

    /// Reads Ollama's (small, JSON) error body without throwing, returning its `error` string.
    private static func readErrorBody(_ bytes: URLSession.AsyncBytes) async -> String? {
        var raw = ""
        do {
            for try await line in bytes.lines {
                raw += line
                if raw.count > 4_000 { break }
            }
        } catch { /* best-effort — fall through to whatever we collected */ }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let body = try? JSONDecoder().decode(OllamaErrorBody.self, from: data),
           !body.error.isEmpty {
            return body.error
        }
        return trimmed
    }

    private static func friendlyChatFailure(status: Int, ollamaError: String?) -> String {
        guard let raw = ollamaError, !raw.isEmpty else {
            return "Ollama request failed (HTTP \(status)). Make sure `ollama serve` is running and the model is pulled."
        }
        if raw.contains("llama-server binary not found") || raw.contains("llama runner") {
            return "Ollama is running but its model runner is missing (no llama-server). Reinstall Ollama from ollama.com (or `brew reinstall ollama`), then `ollama serve` and try again."
        }
        return "Ollama error: \(raw.prefix(300))"
    }
}

// MARK: - Errors & DTOs

public enum InferenceError: Error, Sendable, LocalizedError {
    case invalidBaseURL
    case ollamaUnreachable(String)
    case modelMissing(String, hint: String)
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Invalid Ollama URL in Settings."
        case .ollamaUnreachable(let msg):
            msg
        case .modelMissing(let model, let hint):
            "Model “\(model)” is not installed. \(hint)"
        case .http(_, let message):
            message
        }
    }
}

private struct OllamaChatRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: String
        let images: [String]?

        enum CodingKeys: String, CodingKey {
            case role, content, images
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
            if let images, !images.isEmpty {
                try container.encode(images, forKey: .images)
            }
        }
    }
    struct Options: Encodable, Sendable {
        let numPredict: Int
        enum CodingKeys: String, CodingKey {
            case numPredict = "num_predict"
        }
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let keepAlive: String?
    let think: Bool?
    let options: Options?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, think, options
        case keepAlive = "keep_alive"
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

private struct OllamaErrorBody: Decodable, Sendable {
    let error: String
}

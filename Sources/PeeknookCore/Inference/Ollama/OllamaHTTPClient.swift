// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One Ollama chat message, shared by the streaming and non-streaming paths. Encodes `images`
/// only when non-empty (Ollama treats an empty array as "has images").
public struct OllamaChatMessage: Sendable {
    public var role: String
    public var content: String
    public var images: [String]?

    public init(role: String, content: String, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }

    var jsonObject: [String: Any] {
        var msg: [String: Any] = ["role": role, "content": content]
        if let images, !images.isEmpty { msg["images"] = images }
        return msg
    }
}

/// Single home for the Ollama `/api/chat` policy: `think:false` on the first attempt, a one-shot
/// retry without `think` when a model 400s on it, Ollama error-body parsing, and the friendly
/// failure message. Both the streaming answer pass and the non-streaming follow-up/warm-up pass
/// go through here so the policy lives in exactly one place.
public struct OllamaHTTPClient: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Streaming chat

    /// POSTs `/api/chat` with `stream:true`, `think:false`, `keep_alive`, and (quick mode only)
    /// `options:{num_predict:256}`. On HTTP 400 whose error body mentions "think", retries ONCE
    /// without `think`. On any other non-200 throws `InferenceError.http`. Returns the success
    /// byte stream for the caller to parse chunk lines.
    public func chatStream(
        base: URL,
        model: String,
        messages: [OllamaChatMessage],
        quickMode: Bool,
        keepAlive: String
    ) async throws -> URLSession.AsyncBytes {
        let url = base.appendingPathComponent("api/chat")

        func body(think: Bool?) -> [String: Any] {
            var dict: [String: Any] = [
                "model": model,
                "messages": messages.map(\.jsonObject),
                "stream": true,
                "keep_alive": keepAlive
            ]
            if let think { dict["think"] = think }
            if quickMode { dict["options"] = ["num_predict": 256] }
            return dict
        }

        func send(_ think: Bool?) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            req.httpBody = try JSONSerialization.data(withJSONObject: body(think: think))
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw InferenceError.ollamaUnreachable("No response from Ollama.")
            }
            return (bytes, http)
        }

        // Gemma 4 reasons by default and streams empty `content` until thinking ends; disable it.
        // Not every model supports `think`; if Ollama 400s on it, retry once without it.
        var (bytes, http) = try await send(false)
        if http.statusCode == 400 {
            let detail = await Self.readErrorBody(bytes)
            if (detail ?? "").lowercased().contains("think") {
                (bytes, http) = try await send(nil)
            } else {
                throw InferenceError.http(status: 400, message: Self.friendlyChatFailure(status: 400, ollamaError: detail))
            }
        }
        guard http.statusCode == 200 else {
            // Surface Ollama's actual error body, a generic "check the model" hint hides
            // real failures like a missing llama-server runner.
            let detail = await Self.readErrorBody(bytes)
            throw InferenceError.http(
                status: http.statusCode,
                message: Self.friendlyChatFailure(status: http.statusCode, ollamaError: detail)
            )
        }
        return bytes
    }

    // MARK: - Non-streaming chat

    /// POSTs `/api/chat` non-streaming with the same `think:false` + one-shot 400-think retry +
    /// non-200 error throwing as `chatStream`. Returns the response body Data. `format` is the
    /// JSON-schema dict for schema-constrained output (follow-ups); `options` are inference knobs.
    public func chatData(
        base: URL,
        model: String,
        messages: [OllamaChatMessage],
        stream: Bool,
        keepAlive: String,
        options: [String: Any]?,
        format: [String: Any]?,
        timeout: TimeInterval = 60
    ) async throws -> Data {
        let url = base.appendingPathComponent("api/chat")

        func body(think: Bool?) -> [String: Any] {
            var dict: [String: Any] = [
                "model": model,
                "messages": messages.map(\.jsonObject),
                "stream": stream,
                "keep_alive": keepAlive
            ]
            if let think { dict["think"] = think }
            if let options { dict["options"] = options }
            if let format { dict["format"] = format }
            return dict
        }

        func send(_ think: Bool?) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = timeout
            req.httpBody = try JSONSerialization.data(withJSONObject: body(think: think))
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw InferenceError.ollamaUnreachable("No response from Ollama.")
            }
            return (data, http)
        }

        var (data, http) = try await send(false)
        if http.statusCode == 400 {
            let detail = Self.errorString(from: data)
            if (detail ?? "").lowercased().contains("think") {
                (data, http) = try await send(nil)
            } else {
                throw InferenceError.http(status: 400, message: Self.friendlyChatFailure(status: 400, ollamaError: detail))
            }
        }
        guard http.statusCode == 200 else {
            let detail = Self.errorString(from: data)
            throw InferenceError.http(
                status: http.statusCode,
                message: Self.friendlyChatFailure(status: http.statusCode, ollamaError: detail)
            )
        }
        return data
    }

    // MARK: - Plain streaming POST (no think policy)

    /// POSTs a JSON body and returns the success byte stream for the caller to parse line-by-line.
    /// Does NOT send `think` (used by the setup `pull`). On non-200 throws `InferenceError.http`,
    /// surfacing Ollama's real error body via `readErrorBody` so a failed pull shows its message;
    /// when the body is empty, falls back to `fallbackMessage`.
    public func postStream(
        url: URL,
        body: [String: Any],
        timeout: TimeInterval,
        fallbackMessage: String
    ) async throws -> URLSession.AsyncBytes {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw InferenceError.ollamaUnreachable("No response from Ollama.")
        }
        guard http.statusCode == 200 else {
            let detail = await Self.readErrorBody(bytes)
            throw InferenceError.http(status: http.statusCode, message: detail ?? fallbackMessage)
        }
        return bytes
    }

    // MARK: - Error surfacing

    /// Reads Ollama's (small, JSON) error body from a byte stream without throwing, returning its
    /// `error` string.
    static func readErrorBody(_ bytes: URLSession.AsyncBytes) async -> String? {
        var raw = ""
        do {
            for try await line in bytes.lines {
                raw += line
                if raw.count > 4_000 { break }
            }
        } catch { /* best-effort, fall through to whatever we collected */ }
        return errorString(from: raw)
    }

    /// Parses Ollama's JSON `{ "error": "..." }` body from already-read Data.
    static func errorString(from data: Data) -> String? {
        errorString(from: String(data: data, encoding: .utf8) ?? "")
    }

    private static func errorString(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let body = try? JSONDecoder().decode(OllamaErrorBody.self, from: data),
           !body.error.isEmpty {
            return body.error
        }
        return trimmed
    }

    static func friendlyChatFailure(status: Int, ollamaError: String?) -> String {
        guard let raw = ollamaError, !raw.isEmpty else {
            #if DEBUG
            return "Ollama request failed (HTTP \(status)). Make sure `ollama serve` is running and the model is pulled."
            #else
            return "Couldn't reach Ollama (error \(status)). Open the Ollama app and make sure your model is downloaded, then try again."
            #endif
        }
        if raw.contains("llama-server binary not found") || raw.contains("llama runner") {
            #if DEBUG
            return "Your Ollama install is missing its model runner (no llama-server). Reinstall the Ollama app from ollama.com, or `brew reinstall ollama`, then run `ollama serve` and try again."
            #else
            return "Your Ollama install is missing its model runner. Reinstall the Ollama app from ollama.com, then try again."
            #endif
        }
        return "Ollama error: \(raw.prefix(300))"
    }
}

struct OllamaErrorBody: Decodable, Sendable {
    let error: String
}

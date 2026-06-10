// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Single home for the OpenAI-compatible HTTP policy: bearer-key injection (omitted when keyless —
/// the local-server default), a one-shot retry without `stream_options` when a server 400s on it,
/// and `{"error":{"message":…}}` body parsing. Never logs request bodies or the Authorization
/// header — captures and key material must not reach any log.
public struct OpenAICompatibleHTTPClient: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Streaming chat completions

    /// POSTs `/v1/chat/completions` with `stream:true` and `stream_options.include_usage` (for the
    /// final usage chunk). If the server 400s mentioning `stream_options`, retries ONCE without it
    /// (losing only token stats). On any other non-200 throws `InferenceError.http` with the
    /// server's error message. Returns the SSE byte stream.
    public func chatStream(
        base: URL,
        model: String,
        messages: [OpenAIChatMessage],
        quickMode: Bool,
        apiKey: String?
    ) async throws -> URLSession.AsyncBytes {
        let url = base.appendingPathComponent("v1/chat/completions")

        func body(includeUsage: Bool) -> [String: Any] {
            var dict: [String: Any] = [
                "model": model,
                "messages": messages.map(\.jsonObject),
                "stream": true
            ]
            if includeUsage { dict["stream_options"] = ["include_usage": true] }
            if quickMode { dict["max_tokens"] = 256 }
            return dict
        }

        func send(includeUsage: Bool) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
            let req = try Self.request(
                url: url, json: body(includeUsage: includeUsage), apiKey: apiKey, timeout: 120
            )
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw InferenceError.ollamaUnreachable("No response from the inference server.")
            }
            return (bytes, http)
        }

        var (bytes, http) = try await send(includeUsage: true)
        if http.statusCode == 400 {
            let detail = await Self.readErrorBody(bytes)
            if (detail ?? "").lowercased().contains("stream_options") {
                (bytes, http) = try await send(includeUsage: false)
            } else {
                throw InferenceError.http(
                    status: 400,
                    message: Self.friendlyFailure(status: 400, serverError: detail)
                )
            }
        }
        guard http.statusCode == 200 else {
            let detail = await Self.readErrorBody(bytes)
            throw InferenceError.http(
                status: http.statusCode,
                message: Self.friendlyFailure(status: http.statusCode, serverError: detail)
            )
        }
        return bytes
    }

    // MARK: - Non-streaming chat completions

    /// POSTs `/v1/chat/completions` non-streaming. `responseFormat` is the `response_format`
    /// payload (JSON-schema constrained follow-ups); on non-200 throws `InferenceError.http`.
    public func chatData(
        base: URL,
        model: String,
        messages: [OpenAIChatMessage],
        maxTokens: Int?,
        temperature: Double?,
        responseFormat: [String: Any]?,
        apiKey: String?,
        timeout: TimeInterval = 60
    ) async throws -> Data {
        let url = base.appendingPathComponent("v1/chat/completions")
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(\.jsonObject),
            "stream": false
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        if let temperature { body["temperature"] = temperature }
        if let responseFormat { body["response_format"] = responseFormat }

        let req = try Self.request(url: url, json: body, apiKey: apiKey, timeout: timeout)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw InferenceError.ollamaUnreachable("No response from the inference server.")
        }
        guard http.statusCode == 200 else {
            throw InferenceError.http(
                status: http.statusCode,
                message: Self.friendlyFailure(
                    status: http.statusCode, serverError: OpenAIErrorBody.message(from: data)
                )
            )
        }
        return data
    }

    // MARK: - Model listing

    /// `GET /v1/models` → the served model ids. Throws on non-200 (the caller decides whether
    /// that means "unavailable" or "unknown").
    public func modelIDs(base: URL, apiKey: String?, timeout: TimeInterval = 8) async throws -> [String] {
        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        Self.applyAuthorization(apiKey, to: &req)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InferenceError.ollamaUnreachable("Could not list models on the inference server.")
        }
        return try JSONDecoder().decode(OpenAIModelsResponse.self, from: data).data.map(\.id)
    }

    // MARK: - Request plumbing

    private static func request(
        url: URL, json: [String: Any], apiKey: String?, timeout: TimeInterval
    ) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        applyAuthorization(apiKey, to: &req)
        return req
    }

    private static func applyAuthorization(_ apiKey: String?, to request: inout URLRequest) {
        guard let apiKey, !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Error surfacing

    static func readErrorBody(_ bytes: URLSession.AsyncBytes) async -> String? {
        var raw = ""
        do {
            for try await line in bytes.lines {
                raw += line
                if raw.count > 4_000 { break }
            }
        } catch { /* best-effort, fall through to whatever we collected */ }
        guard let data = raw.data(using: .utf8) else { return nil }
        return OpenAIErrorBody.message(from: data)
    }

    static func friendlyFailure(status: Int, serverError: String?) -> String {
        guard let raw = serverError, !raw.isEmpty else {
            return "The inference server request failed (HTTP \(status)). Make sure the server is running and a model is loaded."
        }
        return "Server error: \(raw.prefix(300))"
    }
}

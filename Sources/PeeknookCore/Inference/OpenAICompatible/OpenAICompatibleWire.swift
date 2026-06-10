// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One OpenAI-compatible chat message. Text-only messages encode `content` as a plain string;
/// messages with images encode the content-array form (`text` part + one `image_url` part per
/// image), so N images per message is native — composite turns later widen only message
/// construction, never this builder.
public struct OpenAIChatMessage: Sendable {
    public var role: String
    public var text: String
    public var imagesBase64: [String]

    public init(role: String, text: String, imagesBase64: [String] = []) {
        self.role = role
        self.text = text
        self.imagesBase64 = imagesBase64
    }

    var jsonObject: [String: Any] {
        ["role": role, "content": Self.contentValue(text: text, imagesBase64: imagesBase64)]
    }

    static func contentValue(text: String, imagesBase64: [String]) -> Any {
        guard !imagesBase64.isEmpty else { return text }
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for base64 in imagesBase64 {
            parts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
            ])
        }
        return parts
    }
}

/// One SSE chunk of `/v1/chat/completions` (and the whole body of a non-streaming response —
/// same shape with `message` instead of `delta`). Tolerant: every field optional.
struct OpenAIChatChunk: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Delta: Decodable, Sendable {
            let content: String?
        }
        let delta: Delta?
        let message: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta, message
            case finishReason = "finish_reason"
        }
    }
    struct Usage: Decodable, Sendable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
    let choices: [Choice]?
    let usage: Usage?
}

/// `GET /v1/models` body.
struct OpenAIModelsResponse: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        let id: String
    }
    let data: [Model]
}

/// Error body, tolerant of both common shapes: `{"error":{"message":"…"}}` (OpenAI) and
/// `{"error":"…"}` (some local servers).
enum OpenAIErrorBody {
    static func message(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        if let object = root["error"] as? [String: Any], let message = object["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let string = root["error"] as? String, !string.isEmpty {
            return string
        }
        return nil
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A profile's optional answer-model override: backend + tag together (so the endpoint always
/// derives from the binding's own backend — a bound model can never be sent to the wrong server).
/// `nil` binding (or an unusable tag) means "use the global answer model". Persisted inside
/// `peeknook.profiles.v1`, so the decode is hand-written and non-throwing: an unknown backend raw
/// (from a newer build) degrades to `.ollama` instead of stranding the whole catalog.
public struct ProfileModelBinding: Codable, Equatable, Sendable {
    public let backend: InferenceBackend
    public let tag: String

    public init(backend: InferenceBackend, tag: String) {
        self.backend = backend
        self.tag = tag
    }

    /// Nil when the tag is empty/whitespace — an empty binding is "no binding", never a
    /// `model: ""` request.
    public init?(backend: InferenceBackend, normalizingTag raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.init(backend: backend, tag: trimmed)
    }

    private enum CodingKeys: String, CodingKey {
        case backend, tag
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let backendRaw = (try? c.decodeIfPresent(String.self, forKey: .backend)) ?? nil
        self.backend = backendRaw.flatMap(InferenceBackend.init(rawValue:)) ?? .ollama
        self.tag = ((try? c.decodeIfPresent(String.self, forKey: .tag)) ?? nil) ?? ""
    }

    public var modelReference: ModelReference {
        ModelReference(backend: backend, tag: tag)
    }

    /// False for an empty/whitespace tag — resolvers fall back to the global model.
    public var hasUsableTag: Bool {
        !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

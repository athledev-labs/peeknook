// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Stable handle to one stored API credential. The ref carries only an identifier — key material
/// lives exclusively in the Keychain behind ``CredentialStoring`` and is resolved at request time,
/// so a ref can travel inside `InferenceEndpoint`/`InferenceRequest` values (and their Equatable
/// conformances) without any secret ever reaching UserDefaults, logs, or settings payloads.
public struct CredentialRef: Hashable, Codable, Sendable {
    /// Keychain account name. Treat as persisted format: changing an id orphans the stored key.
    public let id: String

    public init(id: String) {
        self.id = id
    }

    /// The single app-wide OpenAI-compatible server key (the only slot until profiles bind models).
    public static let openAICompatiblePrimary = CredentialRef(id: "openai-compatible-primary")

    /// Per-profile slot reserved for profiles v1 (per-profile model binding); unused until then.
    public static func openAICompatible(profileID: String) -> CredentialRef {
        CredentialRef(id: "openai-compatible-profile-\(profileID)")
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Backend-neutral inference destination. Deliberately NOT Codable: an endpoint is a transient
/// routing value rebuilt from settings each turn, so an `apiKeyRef` can never be persisted.
public enum InferenceEndpoint: Sendable, Equatable {
    case ollama(baseURL: String, acceptInsecureRemote: Bool)
    /// A local OpenAI-compatible server (LM Studio, vLLM). The key is resolved from the Keychain
    /// at request time via the ref; equality compares the ref id, never key material.
    case openAICompatible(baseURL: String, apiKeyRef: CredentialRef, acceptInsecureRemote: Bool)
}

public extension InferenceEndpoint {
    /// Connection coordinates every HTTP backend shares. Exhaustive on purpose: a new backend case
    /// breaks this switch, forcing the author to route it through `EndpointURLPolicy` (the HTTPS
    /// gate) like the rest.
    var connection: (baseURL: String, acceptInsecureRemote: Bool) {
        switch self {
        case let .ollama(baseURL, acceptInsecureRemote):
            (baseURL, acceptInsecureRemote)
        case let .openAICompatible(baseURL, _, acceptInsecureRemote):
            (baseURL, acceptInsecureRemote)
        }
    }

    var backend: InferenceBackend {
        switch self {
        case .ollama: .ollama
        case .openAICompatible: .openAICompatible
        }
    }

    /// Alias of ``PeeknookSettings/activeEndpoint`` retained for call-site stability.
    static func from(settings: PeeknookSettings) -> InferenceEndpoint {
        settings.activeEndpoint
    }
}

public extension PeeknookSettings {
    /// The endpoint the active backend answers from — rebuilt from settings per call, never
    /// persisted (so the credential ref can't reach UserDefaults).
    var activeEndpoint: InferenceEndpoint {
        switch answerBackend {
        case .ollama:
            .ollama(
                baseURL: ollamaBaseURL,
                acceptInsecureRemote: acceptInsecureRemoteOllama
            )
        case .openAICompatible:
            .openAICompatible(
                baseURL: openAICompatibleBaseURL,
                apiKeyRef: .openAICompatiblePrimary,
                acceptInsecureRemote: acceptInsecureRemoteOpenAICompatible
            )
        }
    }
}

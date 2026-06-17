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

    /// True when this endpoint's base URL targets a host other than local loopback — the same
    /// determination the HTTPS gate makes, reused here so "do we redact secrets before sending?" can
    /// never diverge from "is this remote?".
    var usesRemoteHost: Bool {
        EndpointURLPolicy.usesRemoteHost(connection.baseURL)
    }

    /// Whether text headed to this endpoint with `modelTag` is leaving the Mac, for redaction purposes:
    /// a non-loopback base URL, OR an Ollama `:cloud` tag (which Ollama routes to its hosted models even
    /// from a loopback daemon). Either makes the egress remote.
    func isRemoteEgress(modelTag: String) -> Bool {
        usesRemoteHost || OllamaCatalogClient.isCloudTag(modelTag)
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

    /// The endpoint a routed text-only follow-up answers from, derived from ``textOnlyBackend``.
    /// Reuses the SAME global server fields as ``activeEndpoint`` (base URL, credential ref, insecure
    /// flag) so ``EndpointURLPolicy`` — the HTTPS gate — applies identically; a routed turn can never
    /// bypass it.
    var textOnlyEndpoint: InferenceEndpoint {
        switch textOnlyBackend {
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

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

    /// THE single point where an inference endpoint becomes a usable URL: its base URL run through
    /// ``EndpointURLPolicy`` (the HTTPS / loopback gate). Every engine resolves its request URL through
    /// this and nothing else, so no inference call — however the endpoint was constructed (global,
    /// per-profile binding, or a future per-role binding) — can reach the network without passing the
    /// gate. Constructing an ``InferenceEndpoint`` is cheap and non-throwing precisely because this is
    /// where the cost (and the gate) lives; a new construction site is gated for free the moment it is
    /// used. Throws ``InferenceError/insecureRemoteHTTP`` for a plain-HTTP non-loopback host without the
    /// per-backend opt-in, or ``InferenceError/invalidBaseURL`` for an unusable URL.
    func resolvedBaseURL() throws -> URL {
        let (baseURL, acceptInsecureRemote) = connection
        return try EndpointURLPolicy.resolveOrThrow(baseURL, acceptInsecureRemote: acceptInsecureRemote)
    }

    /// ``resolvedBaseURL()`` plus a backend mis-route guard, for an engine resolving the endpoint it was
    /// handed: an engine only ever serves its own backend, so receiving another is a registry mis-route
    /// (a programmer error). It traps in debug and, like any unusable endpoint, throws
    /// ``InferenceError/invalidBaseURL`` in release rather than issuing a wrong-shaped request. Both
    /// engines resolve their per-turn request URL through this one method, so the gate AND the mis-route
    /// assertion live in a single place and the two engines stay symmetric.
    func resolvedBaseURL(expecting backend: InferenceBackend) throws -> URL {
        guard self.backend == backend else {
            assertionFailure("\(backend) engine received a \(self.backend) endpoint")
            throw InferenceError.invalidBaseURL
        }
        return try resolvedBaseURL()
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

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Backend-neutral inference destination. Ollama is the only shipped case today.
public enum InferenceEndpoint: Sendable, Equatable {
    case ollama(baseURL: String, acceptInsecureRemote: Bool)
}

public extension InferenceEndpoint {
    static func from(settings: PeeknookSettings) -> InferenceEndpoint {
        .ollama(
            baseURL: settings.ollamaBaseURL,
            acceptInsecureRemote: settings.acceptInsecureRemoteOllama
        )
    }
}

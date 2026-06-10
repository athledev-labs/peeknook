// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Maps each ``InferenceBackend`` to its engine. Built only now that a second backend exists
/// (a one-route registry is the speculative plurality §0 forbids); `.sidecar` later means one new
/// entry, not new dispatch code.
public struct InferenceBackendRegistry: Sendable {
    private let engines: [InferenceBackend: any InferenceEngine]

    /// Expects an engine for every backend case; `uniform(_:)` is the one-liner for tests.
    public init(_ engines: [InferenceBackend: any InferenceEngine]) {
        assert(
            InferenceBackend.allCases.allSatisfy { engines[$0] != nil },
            "InferenceBackendRegistry must register every backend: \(InferenceBackend.allCases)"
        )
        self.engines = engines
    }

    public func engine(for backend: InferenceBackend) -> any InferenceEngine {
        if let engine = engines[backend] { return engine }
        // Deterministic release fallback: Ollama is the floor backend and always registered. A
        // mis-route then fails inside the Ollama engine's own endpoint tripwire — loud in DEBUG.
        assertionFailure("No engine registered for backend \(backend.rawValue)")
        guard let fallback = engines[.ollama] else {
            preconditionFailure("InferenceBackendRegistry has no engines registered")
        }
        return fallback
    }

    public func engine(for endpoint: InferenceEndpoint) -> any InferenceEngine {
        engine(for: endpoint.backend)
    }

    /// One engine for every backend — test doubles and the UI-test host.
    public static func uniform(_ engine: any InferenceEngine) -> InferenceBackendRegistry {
        InferenceBackendRegistry(
            Dictionary(uniqueKeysWithValues: InferenceBackend.allCases.map { ($0, engine) })
        )
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Inference backend that hosts a model. Ollama is the only shipped backend today; the enum is
/// completed at endgame shape so a second backend is a new case (a compile tripwire) rather than a
/// schema change. Model identity is always `(backend, normalizedTag)` — see `ModelReference.matches`.
public enum InferenceBackend: String, Codable, Sendable, CaseIterable {
    case ollama
    case openAICompatible
    // case sidecar            // ← Phase 5 agent transport, not a vision backend
}

/// A model capability as reported by the backend (e.g. Ollama's `/api/show` capabilities list).
/// Detected live, never persisted — a model's capabilities can't go stale if we don't store them.
public enum ModelCapability: String, Codable, Sendable {
    case vision
    case textOnly
}

/// The job a model is selected for. Only `primaryVision` has a real slot today; the rest are
/// reserved so the future router (Phase 4) is a value to plug in, not a schema migration. No role
/// *bindings* are persisted yet — the orchestrator uses `PeeknookSettings.answerModel` directly.
public enum ModelRole: String, Sendable, CaseIterable {
    case primaryVision
    case fastVision
    case textOnly
    case toolAgent
}

/// Backend-qualified model identity.
///
/// Today this is a *projection* over `PeeknookSettings.textModel` (see `PeeknookSettings.answerModel`),
/// not a stored type — the persisted key stays `textModel`, so the existing ~20 read sites and 3
/// write sites don't churn. `tag` is the raw Ollama tag; `capabilities` is filled live by the vision
/// gate and is never persisted.
public struct ModelReference: Sendable, Equatable {
    public let backend: InferenceBackend
    public let tag: String
    /// Transient, live-detected (e.g. by ``VisionGate``); never encoded.
    public var capabilities: [ModelCapability]

    public init(backend: InferenceBackend, tag: String, capabilities: [ModelCapability] = []) {
        self.backend = backend
        self.tag = tag
        self.capabilities = capabilities
    }

    /// Canonical tag form (`gemma4` → `gemma4:latest`), shared with ``ModelTag``.
    public var normalizedTag: String { ModelTag.normalized(tag) }

    /// Tag-aware AND backend-aware match. Two backends may host the same tag string, so an Ollama
    /// `gemma4:e2b` must NOT satisfy a (future) `openAICompatible` `gemma4:e2b`; and a distinct tag
    /// never matches (`gemma4:e2b` ≠ `gemma4:e4b`). Extends the ``ModelTag`` invariant across backends.
    /// `capabilities` is identity-irrelevant — it's transient.
    public func matches(_ other: ModelReference) -> Bool {
        backend == other.backend && normalizedTag == other.normalizedTag
    }
}

public extension PeeknookSettings {
    /// The active answer model as a backend-qualified reference, projected from the persisted
    /// `textModel`. The single shipped backend is Ollama; `capabilities` is empty here and filled
    /// live by ``VisionGate`` at read time. When a non-Ollama backend becomes selectable this gains a
    /// stored, tolerant-decoded `answerModel` key — `textModel` is never renamed.
    var answerModel: ModelReference {
        ModelReference(backend: .ollama, tag: textModel)
    }
}

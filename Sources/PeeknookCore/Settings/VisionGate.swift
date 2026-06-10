// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Whether the active model can read the captured screenshot.
///
/// Tri-state on purpose: `.unknown` (model not installed, or an older Ollama that omits the
/// capabilities list) must NEVER block capture, so a pre-install or pre-probe state degrades to
/// "allow, stay quiet" rather than a false text-only warning.
public enum VisionReadiness: Sendable, Equatable {
    /// `/api/show` reports a vision capability — safe to send a screenshot.
    case ready
    /// `/api/show` was reachable and the model has no vision capability — capture should be blocked
    /// (otherwise the screenshot is silently dropped by the model).
    case textOnly
    /// Capability couldn't be determined (not installed / older runtime / heuristic miss). Do not
    /// block on this — the model may still be multimodal once installed.
    case unknown
}

/// Single source of truth for "can this model see the screenshot?", shared by capture enablement,
/// the model library, and the Settings vision banner so the three never disagree.
///
/// Prefers the live, authoritative `/api/show` capabilities (`InferenceEngine.supportsVision`) and
/// only falls back to a name heuristic before the model is installed — and even then never returns
/// `.textOnly`, only `.ready` or `.unknown`, so an uninstalled model can't false-block capture.
///
/// Inert today: no call site routes through it yet (a follow-up slice wires Home capture enablement,
/// the library, and the Settings banner to it).
public struct VisionGate: Sendable {
    private let inference: any InferenceEngine
    /// Pre-install heuristic (name/tag substring match). Production passes
    /// `ModelCatalogService.likelySupportsVision`; tests inject a stub. Consulted only when the live
    /// capability probe returns `nil`.
    private let likelyVision: @Sendable (String) -> Bool

    public init(inference: any InferenceEngine, likelyVision: @escaping @Sendable (String) -> Bool) {
        self.inference = inference
        self.likelyVision = likelyVision
    }

    /// Readiness for the given model tag against an inference endpoint. `tag` is a raw Ollama tag;
    /// `ModelReference` adapts trivially once it lands.
    ///
    /// Backends whose live probe can't answer (an OpenAI-compatible `/v1/models` reports no
    /// capability metadata, so `capabilities` is nil) land in the same degrade path as an
    /// uninstalled Ollama model: `.ready` if the heuristic recognizes the tag, else `.unknown` —
    /// never `.textOnly`, so an unverifiable backend can't false-block capture.
    public func readiness(of tag: String, endpoint: InferenceEndpoint) async -> VisionReadiness {
        guard !ModelTag.normalized(tag).isEmpty else { return .unknown }
        if let supportsVision = await inference.supportsVision(model: tag, endpoint: endpoint) {
            return supportsVision ? .ready : .textOnly
        }
        // Live probe couldn't answer (not installed / older runtime). The heuristic may say "ready",
        // but it must never say "textOnly" — an uninstalled model cannot block capture.
        return likelyVision(tag) ? .ready : .unknown
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The model + endpoint a single turn is routed to, resolved from a ``ModelRole``. A transient
/// routing projection (like ``InferenceEndpoint``, rebuilt per call) — deliberately NOT Codable, so
/// no role binding can reach UserDefaults. Pairing the model with its endpoint means a call site can
/// never stream a model to the wrong server.
public struct RoleResolution: Sendable, Equatable {
    public let model: ModelReference
    public let endpoint: InferenceEndpoint

    public init(model: ModelReference, endpoint: InferenceEndpoint) {
        self.model = model
        self.endpoint = endpoint
    }
}

public extension PeeknookSettings {
    /// Resolves the model + endpoint for a ``ModelRole`` against a profile. The switch is exhaustive
    /// over `ModelRole` on purpose: when Live (v1.3) gives `fastVision` a real binding, the compiler
    /// forces that arm to be written rather than letting it silently fall through.
    ///
    /// Today only `.textOnly` diverges, and only when a text-only model is configured. Every other
    /// role — and an unconfigured `.textOnly` — resolves the profile's primary vision model
    /// (``answerModel(for:)`` / ``endpoint(for:)``), byte-identical to pre-router behavior.
    func resolved(role: ModelRole, for profile: GroundProfile) -> RoleResolution {
        switch role {
        case .primaryVision, .fastVision, .toolAgent:
            // Deferred stubs: no binding yet, so they answer with the profile's primary vision model.
            return RoleResolution(model: answerModel(for: profile), endpoint: endpoint(for: profile))
        case .textOnly:
            guard let model = textOnlyModel else {
                return RoleResolution(model: answerModel(for: profile), endpoint: endpoint(for: profile))
            }
            return RoleResolution(model: model, endpoint: textOnlyEndpoint)
        }
    }
}

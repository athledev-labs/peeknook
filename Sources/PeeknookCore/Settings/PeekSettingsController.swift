// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Canonical read/write API for ``PeeknookSettings``, keeps orchestrator, setup, and
/// UserDefaults in sync so Home and Settings cannot drift.
///
/// The public surface is split by area into `PeekSettingsController+*` extension files
/// (General, Live, Backend, Profiles, CommandLayout, Models), mirroring the
/// ``SessionOrchestrator`` facade pattern. This base file owns only the type, init, the five
/// injected deps, and the shared update/persist seam every setter funnels through.
@MainActor
@Observable
public final class PeekSettingsController {
    let orchestrator: SessionOrchestrator
    let setup: SetupCoordinator
    let defaults: UserDefaults
    let inferenceRegistry: InferenceBackendRegistry
    let credentialStore: any CredentialStoring
    /// The engine for the active backend, resolved per call (matches the orchestrator's shim).
    /// primaryVision-only — health/warm checks here never stream a routed text-only turn; per-role
    /// turn streaming lives in ``SessionOrchestrator/inference(for:)``.
    var inference: any InferenceEngine {
        inferenceRegistry.engine(for: settings.answerModel.backend)
    }

    public var settings: PeeknookSettings { orchestrator.settings }

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        defaults: UserDefaults,
        inferenceRegistry: InferenceBackendRegistry,
        credentialStore: any CredentialStoring = InMemoryCredentialStore()
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.defaults = defaults
        self.inferenceRegistry = inferenceRegistry
        self.credentialStore = credentialStore
    }

    /// Single-engine convenience for tests and simple hosts (wraps a uniform registry).
    public convenience init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        defaults: UserDefaults,
        inference: any InferenceEngine
    ) {
        self.init(
            orchestrator: orchestrator,
            setup: setup,
            defaults: defaults,
            inferenceRegistry: .uniform(inference)
        )
    }

    /// Mutate in-memory settings and persist once to `peeknook.settings.v1`.
    public func update(_ mutate: (inout PeeknookSettings) -> Void) {
        mutate(&orchestrator.settings)
        persist()
    }

    public func persist() {
        orchestrator.persistSettings(to: defaults)
    }
}

/// Filters installed Ollama tags to those not already listed in the picker.
public enum ModelTagDiscovery {
    public static func undiscovered(installedNames: [String], knownTags: [String]) -> [String] {
        let known = Set(knownTags.map { OllamaSetupClient.normalizedTag($0) })
        var seen = Set<String>()
        var result: [String] = []
        for name in installedNames {
            let key = OllamaSetupClient.normalizedTag(name)
            guard !key.isEmpty, !known.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

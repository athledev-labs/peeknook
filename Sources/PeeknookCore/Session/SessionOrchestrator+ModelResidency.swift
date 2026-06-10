// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
extension SessionOrchestrator {
    /// Whether Ollama's `/api/ps` last reported the active answer model as loaded in memory.
    /// Complements the in-session `lastInferenceAt` heuristic so a relaunch after Ollama kept
    /// the model warm still shows honest "Reading the screen…" copy instead of cold-load text.
    func refreshActiveModelResidency() async {
        switch activeInferenceEndpoint {
        case let .ollama(baseURL, acceptInsecureRemote):
            let client = ollamaResidencyClient
            let running = (try? await client.runningModelFootprints(
                baseURL: baseURL,
                acceptInsecureRemote: acceptInsecureRemote
            )) ?? []
            activeModelResidentInMemory = OllamaSetupClient.matchesModel(
                installedNames: running.map(\.name),
                wanted: activeAnswerModel.tag
            )
        case .openAICompatible:
            activeModelResidentInMemory = false
        }
    }

    private var ollamaResidencyClient: OllamaSetupClient {
        _ollamaResidencyClient ?? OllamaSetupClient()
    }
}

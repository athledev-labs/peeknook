// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

public enum SetupStepState: Sendable, Equatable {
    case pending
    case inProgress(String)
    case complete
    case failed(String)
}

@MainActor
@Observable
public final class SetupCoordinator {
    public private(set) var ollamaStep: SetupStepState = .pending
    public private(set) var modelStep: SetupStepState = .pending
    public private(set) var captureStep: SetupStepState = .pending
    public private(set) var smokeTestStep: SetupStepState = .pending
    public private(set) var isRefreshing = false
    public private(set) var isPullingModel = false
    public private(set) var pullStatusLine: String?
    public private(set) var installedModelNames: [String] = []

    public var settings: PeeknookSettings
    public weak var orchestrator: SessionOrchestrator?
    private let defaults: UserDefaults
    private let ollama = OllamaSetupClient()
    private var pullTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(settings: PeeknookSettings, defaults: UserDefaults) {
        self.settings = settings
        self.defaults = defaults
        if defaults.bool(forKey: Self.smokeTestKey) {
            smokeTestStep = .complete
        }
    }

    public static let smokeTestKey = "peeknook.setup.smokeTest.v1"
    public static let onboardingCompleteKey = "peeknook.setup.onboardingComplete.v1"

    /// User finished or skipped past the first-run setup drill-in (persisted).
    public var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: Self.onboardingCompleteKey)
    }

    public var isReady: Bool {
        ollamaStep == .complete && modelStep == .complete && captureStep == .complete
    }

    public var suggestedModelDiskHint: String {
        if let option = TextModelCatalog.option(for: settings.textModel),
           let size = option.downloadHint {
            return "\(size) model file"
        }
        return "Large model file"
    }

    public func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    public func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let status = await ollama.status(
            baseURL: settings.ollamaBaseURL,
            model: settings.textModel
        )

        if status.isReachable {
            ollamaStep = .complete
            installedModelNames = await ollama.installedModelNames(baseURL: settings.ollamaBaseURL)
        } else {
            ollamaStep = .failed(status.reachabilityMessage)
            modelStep = .pending
            installedModelNames = []
            if !isPullingModel { captureStep = evaluateCaptureStep() }
            return
        }

        if status.isModelInstalled {
            modelStep = .complete
            pullStatusLine = nil
        } else if !isPullingModel {
            modelStep = .pending
        }

        captureStep = evaluateCaptureStep()
    }

    public func pullRecommendedModel() {
        guard !isPullingModel else { return }
        isPullingModel = true
        modelStep = .inProgress("Starting download…")
        pullStatusLine = "Connecting to Ollama…"

        pullTask?.cancel()
        pullTask = Task {
            do {
                for try await event in ollama.pullModel(
                    baseURL: settings.ollamaBaseURL,
                    model: settings.textModel
                ) {
                    if Task.isCancelled { break }
                    switch event {
                    case .status(let line):
                        pullStatusLine = line
                        modelStep = .inProgress(line)
                    case .completed:
                        modelStep = .complete
                        pullStatusLine = nil
                    }
                }
            } catch {
                if !Task.isCancelled {
                    modelStep = .failed(error.localizedDescription)
                    pullStatusLine = nil
                }
            }
            isPullingModel = false
            await refresh()
        }
    }

    public func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        isPullingModel = false
        pullStatusLine = nil
    }

    public func markSmokeTestPassed() {
        smokeTestStep = .complete
        defaults.set(true, forKey: Self.smokeTestKey)
    }

    public func markOnboardingComplete() {
        defaults.set(true, forKey: Self.onboardingCompleteKey)
    }

    public func applyRecommendedModelIfNeeded() {
        let suggested = SystemProfile.current().suggestedTextModel
        if settings.textModel.isEmpty {
            settings.textModel = suggested
            settings.save(to: defaults)
        }
    }

    public func persistSettings() {
        settings.save(to: defaults)
        orchestrator?.settings = settings
    }

    public func isModelInstalled(_ model: String) -> Bool {
        Self.matchesModel(installedNames: installedModelNames, wanted: model)
    }

    public func selectTextModel(_ model: String) {
        settings.textModel = model
        persistSettings()
        Task {
            await refresh()
            orchestrator?.prewarm()
        }
    }

    private static func matchesModel(installedNames: [String], wanted: String) -> Bool {
        OllamaSetupClient.matchesModel(installedNames: installedNames, wanted: wanted)
    }

    private func evaluateCaptureStep() -> SetupStepState {
        let permissions = CapturePermissionStatus.current()
        if permissions.screenRecordingGranted {
            return .complete
        }
        return .failed("Screen Recording is required so the model can see your screen.")
    }
}

#if canImport(AppKit)
import AppKit

public extension SetupCoordinator {
    @MainActor
    static func openOllamaDownload() {
        if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openOllamaApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ollama.ollama") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            openOllamaDownload()
        }
    }
}
#endif

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
    /// When true, ``refresh()`` is a no-op and ``isReady`` does not require live TCC probes.
    public var skipsLiveProbes = false
    private let defaults: UserDefaults
    private let ollama = OllamaSetupClient()
    /// Live TCC status, injectable so readiness is testable without the real Privacy database.
    private let permissionStatusProvider: @MainActor () -> CapturePermissionStatus
    private var pullTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(
        settings: PeeknookSettings,
        defaults: UserDefaults,
        permissionStatus: @escaping @MainActor () -> CapturePermissionStatus = { CapturePermissionStatus.current() }
    ) {
        self.settings = settings
        self.defaults = defaults
        self.permissionStatusProvider = permissionStatus
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

    public var isReady: Bool { readiness(for: settings.activeProfile) }

    /// Per-profile readiness: setup steps complete, then (unless probes are bypassed) every
    /// permission the profile's active grounds require is granted. `screen.default` requires only
    /// Screen Recording, so this is behavior-identical to the old monolithic gate today; a
    /// `camera.*` profile will require Camera (and NOT Screen Recording) when it ships.
    public func readiness(for profile: GroundProfile) -> Bool {
        guard ollamaStep == .complete, modelStep == .complete else { return false }
        if skipsLiveProbes { return true }
        return Self.permissionsSatisfied(for: profile, status: permissionStatusProvider())
    }

    /// Pure permission half of the readiness decision, testable without driving private setup state.
    static func permissionsSatisfied(for profile: GroundProfile, status: CapturePermissionStatus) -> Bool {
        profile.requiredPermissions.allSatisfy { status.grants($0) }
    }

    /// The active profile's required permissions and their live granted state, for the
    /// profile-conditional setup checklist. `screen.default` yields a single Screen Recording row, so
    /// the checklist is unchanged today; a `camera.*` profile would yield a Camera row instead.
    public var permissionChecklist: [PermissionRequirement] {
        permissionChecklist(for: settings.activeProfile)
    }

    public func permissionChecklist(for profile: GroundProfile) -> [PermissionRequirement] {
        let status = permissionStatusProvider()
        return profile.requiredPermissions
            .sorted { $0.rawValue < $1.rawValue }
            .map { PermissionRequirement(permission: $0, isGranted: status.grants($0)) }
    }

    /// Cheap sync refresh for Screen Recording only, used before capture and on a fast poll.
    public func refreshCapturePermission() {
        if skipsLiveProbes { return }
        captureStep = evaluateCaptureStep()
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

    /// Seeds setup steps as complete for deterministic UI tests and unit tests that inject mocks.
    public func applyTestBypass() {
        skipsLiveProbes = true
        ollamaStep = .complete
        modelStep = .complete
        captureStep = .complete
        installedModelNames = [settings.textModel]
        markOnboardingComplete()
    }

    public func refresh() async {
        if skipsLiveProbes { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // A non-Ollama backend runs its own server and loads its own models — the Ollama
        // onboarding steps don't apply, and readiness must not demand a running Ollama. Server
        // health surfaces in the Settings status banner (endpoint-typed health), not here.
        guard settings.answerBackend == .ollama else {
            ollamaStep = .complete
            modelStep = .complete
            pullStatusLine = nil
            installedModelNames = []
            captureStep = evaluateCaptureStep()
            return
        }

        let status = await ollama.status(
            baseURL: settings.ollamaBaseURL,
            model: settings.textModel,
            acceptInsecureRemote: settings.acceptInsecureRemoteOllama
        )

        if status.isReachable {
            ollamaStep = .complete
            installedModelNames = await ollama.installedModelNames(
                baseURL: settings.ollamaBaseURL,
                acceptInsecureRemote: settings.acceptInsecureRemoteOllama
            )
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
                    model: settings.textModel,
                    acceptInsecureRemote: settings.acceptInsecureRemoteOllama
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
        // Ollama-only: seeding a Gemma tag while the user is on an OpenAI-compatible server would
        // overwrite nothing they see, but `textModel` must stay theirs to come back to.
        guard settings.answerBackend == .ollama else { return }
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

    private static func matchesModel(installedNames: [String], wanted: String) -> Bool {
        OllamaSetupClient.matchesModel(installedNames: installedNames, wanted: wanted)
    }

    private func evaluateCaptureStep() -> SetupStepState {
        if skipsLiveProbes { return .complete }
        let status = permissionStatusProvider()
        let missing = settings.activeProfile.requiredPermissions
            .filter { !status.grants($0) }
            .sorted { $0.rawValue < $1.rawValue }
        if missing.isEmpty { return .complete }
        // Preserve the legacy copy for the shipped screen profile.
        if missing == [.screenRecording] {
            return .failed("Screen Recording is required so the model can see your screen.")
        }
        let names = missing.map(\.displayName).joined(separator: " and ")
        return .failed("\(names) \(missing.count == 1 ? "is" : "are") required for the active profile.")
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

// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

public enum SetupStepState: Sendable, Equatable {
    case pending
    case inProgress(String)
    case complete
    /// Previously satisfied, but an upstream prerequisite (Ollama) is currently down, so there is
    /// nothing to do on this row. Distinct from `.failed` (an actionable problem) and never equal to
    /// `.complete`, so it can NEVER make setup "ready" — do not add `.blocked` to any readiness OR.
    case blocked(String)
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
    /// User-profile catalog (set by `PeeknookServices.makeStack`); nil = built-ins only. Setup and
    /// the orchestrator share ONE store so they always resolve the same active profile.
    public var profileStore: ProfileStore?
    /// When true, ``refresh()`` is a no-op and ``isReady`` does not require live TCC probes.
    public var skipsLiveProbes = false
    private let defaults: UserDefaults
    private let ollama: OllamaSetupClient
    /// Shared health-probe coalescer (nil = no coalescing). Held so a completed pull can invalidate the
    /// `/api/tags` cache before the post-pull refresh re-reads it.
    private let probeCache: OllamaProbeCache?
    /// Live TCC status, injectable so readiness is testable without the real Privacy database.
    private let permissionStatusProvider: @MainActor () -> CapturePermissionStatus
    private var pullTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(
        settings: PeeknookSettings,
        defaults: UserDefaults,
        probeCache: OllamaProbeCache? = nil,
        permissionStatus: @escaping @MainActor () -> CapturePermissionStatus = { CapturePermissionStatus.current() }
    ) {
        self.settings = settings
        self.defaults = defaults
        self.probeCache = probeCache
        self.ollama = OllamaSetupClient(probeCache: probeCache)
        self.permissionStatusProvider = permissionStatus
        // Seed the known-installed set from the last reachable probe so an offline first paint (e.g. a
        // relaunch with Ollama quit) can report the model as installed-but-blocked, not missing.
        installedModelNames = Self.loadLastInstalledModels(from: defaults)
        if defaults.bool(forKey: Self.smokeTestKey) {
            smokeTestStep = .complete
        }
    }

    public static let smokeTestKey = "peeknook.setup.smokeTest.v1"
    public static let onboardingCompleteKey = "peeknook.setup.onboardingComplete.v1"
    /// Last installed-model tags seen on a reachable probe, persisted so a relaunch while Ollama is
    /// offline still knows the model is there (the model row stays "installed", not "download me").
    /// Read tolerantly (`?? []`); standalone key, never part of PeeknookSettings Codable; never feeds readiness.
    static let lastInstalledModelsKey = "peeknook.setup.lastInstalledModels.v1"

    static func loadLastInstalledModels(from defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: lastInstalledModelsKey) ?? []
    }

    /// User finished or skipped past the first-run setup drill-in (persisted).
    public var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: Self.onboardingCompleteKey)
    }

    public var isReady: Bool { readiness(for: resolvedActiveProfile) }

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
        permissionChecklist(for: resolvedActiveProfile)
    }

    /// The same resolver the orchestrator uses (built-ins + user catalog → `screen.default`).
    private var resolvedActiveProfile: GroundProfile {
        GroundProfile.resolve(
            id: settings.activeProfileID,
            in: profileStore?.catalog.profiles ?? []
        )
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
            // The list comes back on the status probe itself now — no second `/api/tags` round trip.
            // Persist it so an offline relaunch still knows what's installed.
            rememberInstalledModels(status.installedNames)
        } else {
            ollamaStep = .failed(status.reachabilityMessage)
            // The server is down, so `/api/tags` can't be re-read — but that does NOT mean the model
            // vanished. Keep the last-known installed set (seeded from disk at init, refreshed on every
            // reachable probe). If we last saw the model installed, the row is blocked-on-server with no
            // action; only a genuinely never-installed model stays `.pending` (the first-run download
            // CTA). NEVER wipe the set here — wiping it is exactly what made the row flip to "download me".
            if !isPullingModel {
                if installedModelNames.isEmpty {
                    installedModelNames = Self.loadLastInstalledModels(from: defaults)
                }
                modelStep = isModelInstalled(settings.textModel)
                    ? .blocked("Installed. Waiting for Ollama to come back online.")
                    : .pending
                captureStep = evaluateCaptureStep()
            }
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
                    modelStep = .complete
                    pullStatusLine = nil
                }
            }
            isPullingModel = false
            // The pull changed the installed-model set; drop the cached `/api/tags` so the refresh
            // below (and any concurrent consumer) sees the newly installed tag, not a stale list.
            await probeCache?.invalidate(baseURL: settings.ollamaBaseURL)
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

    /// Records the installed-model set from a reachable probe and persists it (only on change, to avoid
    /// churn from the 3s auto-refresh). The persisted copy lets an offline relaunch stay honest about
    /// what's installed. NEVER called from the unreachable path — that keeps the set sticky.
    func rememberInstalledModels(_ names: [String]) {
        guard names != installedModelNames else { return }
        installedModelNames = names
        defaults.set(names, forKey: Self.lastInstalledModelsKey)
    }

    private static func matchesModel(installedNames: [String], wanted: String) -> Bool {
        OllamaSetupClient.matchesModel(installedNames: installedNames, wanted: wanted)
    }

    private func evaluateCaptureStep() -> SetupStepState {
        if skipsLiveProbes { return .complete }
        let status = permissionStatusProvider()
        let missing = resolvedActiveProfile.requiredPermissions
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

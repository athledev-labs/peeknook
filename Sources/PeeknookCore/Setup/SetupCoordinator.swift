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
    /// Can't determine the state yet — e.g. Ollama is down, so `/api/tags` can't be read and we have
    /// no cached install list. Non-actionable like `.blocked`, but means "not looked" rather than
    /// "installed, waiting": it must NOT show an affirmative "Download model" CTA from a state where
    /// we provably can't know. Never equal to `.complete`; NEVER feeds readiness.
    case unknown(String)
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
    /// 0–1 download progress aggregated across layers; nil before any total is known (then the bar is
    /// indeterminate — we never fake a determinate value).
    public private(set) var pullFraction: Double?
    /// Friendly remaining-time estimate (e.g. "about 4 min left"), only once progress is meaningful.
    public private(set) var pullETA: String?
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
    /// Injectable free-disk probe for the model-download pre-check (default reads the real volume).
    private let storageProbe: ModelStorageProbe
    private var pullTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pullStartedAt: Date?

    public init(
        settings: PeeknookSettings,
        defaults: UserDefaults,
        probeCache: OllamaProbeCache? = nil,
        storageProbe: ModelStorageProbe = FileManagerModelStorageProbe(),
        permissionStatus: @escaping @MainActor () -> CapturePermissionStatus = { CapturePermissionStatus.current() }
    ) {
        self.settings = settings
        self.defaults = defaults
        self.probeCache = probeCache
        self.ollama = OllamaSetupClient(probeCache: probeCache)
        self.storageProbe = storageProbe
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
    /// First-run welcome was shown once. Standalone `peeknook.*` defaults key (NOT part of
    /// PeeknookSettings Codable — invariant #3 safe); a missing key reads false, so the welcome
    /// shows exactly once on a fresh install.
    public static let welcomeSeenKey = "peeknook.setup.welcomeSeen.v1"
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

    /// The one-time welcome screen has been shown (persisted). False on a fresh install.
    public var welcomeSeen: Bool {
        defaults.bool(forKey: Self.welcomeSeenKey)
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

    /// The active profile's required permissions that are NOT currently granted, sorted stably.
    /// The testable seam capture routing keys off to distinguish "only a permission is missing"
    /// (→ the typed permission card) from "install side also incomplete" (→ the blanket
    /// "Finish setup first" card). Reuses the SAME injectable `permissionStatusProvider` and
    /// `resolvedActiveProfile` that ``readiness(for:)`` depends on, so it generalizes past
    /// `screen.default` and is testable without the live Privacy database.
    public var missingActivePermissions: [CapturePermission] {
        resolvedActiveProfile.requiredPermissions
            .filter { !permissionStatusProvider().grants($0) }
            .sorted { $0.rawValue < $1.rawValue }
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
        markWelcomeSeen()
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
                if isModelInstalled(settings.textModel) {
                    // We have a cached reachable probe that saw this tag → it's installed, just waiting.
                    modelStep = .blocked("Installed. Waiting for Ollama to come back online.")
                } else if installedModelNames.isEmpty {
                    // Never connected, so the install set is unknown — don't assert "not installed"
                    // and don't invite a needless re-download. Gate on starting Ollama instead.
                    modelStep = .unknown("Start Ollama to check what's installed.")
                } else {
                    // We DID look (non-empty cached list) and this tag genuinely isn't there → the
                    // legitimate Download CTA.
                    modelStep = .pending
                }
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
        guard passesDiskCheck() else { return }   // sets a sized .failed and bails when space is short
        isPullingModel = true
        modelStep = .inProgress("Getting ready to download…")
        pullStatusLine = "Getting ready to download…"
        pullFraction = nil
        pullETA = nil
        pullStartedAt = Date()

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
                    case .progress(let progress):
                        let line = Self.phaseLabel(progress.phase)
                        pullStatusLine = line
                        modelStep = .inProgress(line)
                        pullFraction = progress.fraction
                        updateETA(progress)
                    case .completed:
                        modelStep = .complete
                        pullStatusLine = nil
                        pullFraction = nil
                        pullETA = nil
                    }
                }
            } catch {
                if !Task.isCancelled {
                    // Honest failure (was wrongly `.complete`): `.failed` re-shows the Download button for
                    // a free retry. The post-pull refresh below still re-evaluates against Ollama.
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? "Download stopped. Check your connection and Ollama, then try again."
                    modelStep = .failed(message)
                    pullStatusLine = nil
                    pullFraction = nil
                    pullETA = nil
                }
            }
            isPullingModel = false
            pullStartedAt = nil
            // The pull changed the installed-model set; drop the cached `/api/tags` so the refresh
            // below (and any concurrent consumer) sees the newly installed tag, not a stale list.
            await probeCache?.invalidate(baseURL: settings.ollamaBaseURL)
            await refresh()
        }
    }

    /// Free-space pre-check before a multi-GB pull. Returns true (no block) for remote Ollama (we
    /// can't and must not read a remote disk), an unknown model size, or an unresolvable probe;
    /// otherwise blocks with a sized `.failed` message when free space is below the estimate plus
    /// working headroom (manifest + temp blobs).
    private func passesDiskCheck() -> Bool {
        guard !settings.usesRemoteOllama,
              let option = TextModelCatalog.option(for: settings.textModel, custom: settings.customModels),
              let estimate = option.estimatedDownloadBytes,
              let available = storageProbe.availableBytesForModelStore() else {
            return true
        }
        let required = estimate + max(2_000_000_000, estimate / 10)
        guard available < required else { return true }
        modelStep = .failed(
            "Needs about \(ByteFormat.storage(required)) free, but only \(ByteFormat.storage(available)) is available. Free up some space and try again."
        )
        pullFraction = nil
        pullETA = nil
        return false
    }

    /// Plain-English phase label (the view localizes it via `Text(peek:)`); also feeds the shared
    /// `pullStatusLine` the Model Library and Settings rows read.
    private static func phaseLabel(_ phase: PullPhase) -> String {
        switch phase {
        case .preparing: return "Getting ready to download…"
        case .downloading: return "Pulling the model…"
        case .verifying: return "Checking the download…"
        case .finishing: return "Finishing up…"
        }
    }

    private func updateETA(_ progress: PullProgress) {
        guard let fraction = progress.fraction, fraction >= 0.03,
              let total = progress.totalBytes, let done = progress.completedBytes, done > 0,
              let started = pullStartedAt else {
            pullETA = nil
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed >= 5 else { pullETA = nil; return }
        let throughput = Double(done) / elapsed
        guard throughput > 0 else { pullETA = nil; return }
        pullETA = Self.formatETA(Double(total - done) / throughput)
    }

    static func formatETA(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 90 { return "about \(max(1, Int(seconds.rounded()))) sec left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }

    public func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        isPullingModel = false
        pullStatusLine = nil
        pullFraction = nil
        pullETA = nil
        pullStartedAt = nil
    }

    public func markSmokeTestPassed() {
        smokeTestStep = .complete
        defaults.set(true, forKey: Self.smokeTestKey)
    }

    public func markOnboardingComplete() {
        defaults.set(true, forKey: Self.onboardingCompleteKey)
    }

    /// Records that the first-run welcome was shown, so it never reappears.
    public func markWelcomeSeen() {
        defaults.set(true, forKey: Self.welcomeSeenKey)
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
            return .failed("Screen Recording is required so the model can see your screen. If the row stays orange after you enable it, quit and reopen Peeknook.")
        }
        let names = missing.map(\.displayName).joined(separator: " and ")
        return .failed("\(names) \(missing.count == 1 ? "is" : "are") required for the active profile.")
    }
}

#if canImport(AppKit)
import AppKit

public extension SetupCoordinator {
    /// Whether the Ollama app is installed (LaunchServices resolves its bundle id). Drives the setup
    /// row's primary action: lead with "Get Ollama app" when it's absent, instead of a misleading
    /// "Open Ollama" that silently bounces to the download page.
    @MainActor
    var isOllamaAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ollama.ollama") != nil
    }

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

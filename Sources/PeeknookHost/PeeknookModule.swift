// SPDX-License-Identifier: Apache-2.0

import Foundation
import NookApp
import PeeknookCore
import PeeknookUI
import SwiftUI

/// Quiet contextual label for the home top bar, breadcrumb drill-ins still win.
private enum PeekTopBarDate {
    nonisolated static func label() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return formatter.string(from: Date())
    }
}

/// Peeknook practice copilot, one module in a multi-module OpenNook host.
@MainActor
public final class PeeknookModule: NookModule {
    nonisolated public static let moduleDescriptor = NookModuleDescriptor(
        id: PeeknookModuleID.peeknook,
        displayName: "Peeknook",
        icon: "sparkles.rectangle.stack",
        accent: .teal,
        backgroundPolicy: .stayResident
    )

    public let descriptor = PeeknookModule.moduleDescriptor
    private let context: NookModuleContext
    private let orchestrator: SessionOrchestrator
    private let setup: SetupCoordinator
    private let usage: UsageStore
    private let settings: PeekSettingsController
    private let modelCatalog: ModelCatalogService
    private let storageFootprint: any StorageFootprinting
    private weak var appCoordinator: AppCoordinator?
    private var previewPhaseTask: Task<Void, Never>?
    private var previewPinHandle: NookPresentationPinHandle?

    public init(context: NookModuleContext) {
        self.context = context
        var loaded = PeeknookSettings.load(from: context.defaults)
        let dependencies: PeeknookDependencies
        if PeeknookTestMode.isEnabled {
            loaded.previewBeforeInfer = false
            dependencies = PeeknookDependencies.testing(
                capture: StubCaptureProvider(sampleText: "uitest screen"),
                inference: MockInferenceEngine(tokens: ["test", " answer"]),
                conversationArchive: ConversationArchiveStore.makeForTesting(),
                cameraSession: StubCameraSession()
            )
        } else {
            dependencies = .production()
        }
        let stack = PeeknookServices.makeStack(
            settings: loaded,
            defaults: context.defaults,
            dependencies: dependencies
        )
        if PeeknookTestMode.isEnabled {
            stack.setup.applyTestBypass()
        }
        self.orchestrator = stack.orchestrator
        self.setup = stack.setup
        self.usage = stack.usage
        self.settings = stack.settings
        self.modelCatalog = stack.modelCatalog
        self.storageFootprint = stack.storageFootprint
    }

    public func makeConfiguration() -> NookConfiguration {
        var configuration = NookConfiguration()
        configuration.setHome {
            PeekRootView(
                orchestrator: self.orchestrator,
                setup: self.setup,
                settings: self.settings,
                modelCatalog: self.modelCatalog
            )
        }
        configuration.setCompactTrailing {
            PeekCompactView(
                orchestrator: self.orchestrator,
                setup: self.setup,
                onExpand: { [weak self] in
                    guard let coordinator = self?.appCoordinator else { return }
                    coordinator.showHome()
                    coordinator.showNook()
                }
            )
        }
        configuration.setSettings {
            PeekSettingsView(
                orchestrator: self.orchestrator,
                setup: self.setup,
                settings: self.settings,
                modelCatalog: self.modelCatalog,
                usage: self.usage,
                storageFootprint: self.storageFootprint,
                onCaptureHotkeyChange: { [weak self] _ in
                    guard let self, let coordinator = self.appCoordinator else { return }
                    self.registerHotkeys(on: coordinator)
                },
                onBriefHotkeyChange: { [weak self] _ in
                    guard let self, let coordinator = self.appCoordinator else { return }
                    self.registerHotkeys(on: coordinator)
                },
                onCameraHotkeyChange: { [weak self] _ in
                    guard let self, let coordinator = self.appCoordinator else { return }
                    self.registerHotkeys(on: coordinator)
                }
            )
        }
        // Date is ambient home chrome only, drilled-in surfaces (Settings, module
        // breadcrumb) use a stable back label so the route reads "Home › Settings",
        // not "Friday, Jun 5 › Settings".
        configuration.topBar.leadingTitle = { appState in
            let hasBreadcrumb = appState.moduleBreadcrumb?.isEmpty == false
            if appState.isSettingsView || hasBreadcrumb {
                return "Home"
            }
            return PeekTopBarDate.label()
        }
        // Peeknook's module glyph, not the default OpenNook notch mark (see NookMarkView).
        configuration.topBar.leadingIcon = Self.moduleDescriptor.icon
        configuration.topBar.width = .contentColumn
        configuration.expandedWidth = 600
        configuration.style = NookStyle(
            topCornerRadius: 19,
            bottomCornerRadius: 24,
            expandedContentInsets: NookEdgeInsets(top: 0, bottom: 2, leading: 8, trailing: 8)
        )
        configuration.theme = { appState in
            var theme = NookResolvedTheme.live(appState: appState)
            if appState.appearancePreferences.accentPreset == .system {
                theme.accent = Self.moduleDescriptor.accent
            }
            return theme
        }
        // Global (always-available, app-level) actions live in the chrome's trailing top-bar
        // cluster next to the lock/gear; phase- and thread-specific actions stay in the in-content
        // bottom command bars. See PeekGlobalTopBarItems for the top/bottom placement rule.
        configuration.setTopBarTrailingItems {
            PeekGlobalTopBarItems(orchestrator: self.orchestrator)
        }
        // PRIVACY KILL-PATH: nook-collapse and hide are NOT phase changes, so the phase-observation
        // loop below can never see them. These hooks fire the camera cancel unconditionally — it is
        // a no-op outside `.cameraLive` and idempotent against the loop's own pin release. Without
        // this, a `.stayResident` module would keep the camera running with no visible UI.
        // They ALSO disarm any live session: an armed thread must never linger with no visible chip,
        // and there is no orchestrator re-show hook to re-arm on expand — collapse is a full disarm.
        configuration.onCompact = { [weak self] in
            self?.orchestrator.cancelCameraLive()
            self?.orchestrator.stopLiveSession()
        }
        configuration.onHide = { [weak self] in
            self?.orchestrator.cancelCameraLive()
            self?.orchestrator.stopLiveSession()
        }
        configuration.onReady = { [weak self] coordinator in
            self?.registerHotkeys(on: coordinator)
            self?.startPreviewPhaseHandling(on: coordinator)
            // Accessory apps have no main menu, so ⌘A/⌘C/⌘V/⌘X/⌘Z don't reach text fields.
            StandardEditMenu.installIfNeeded()
            if PeeknookTestMode.isEnabled {
                coordinator.showHome()
                coordinator.showNook()
                if PeeknookTestMode.opensSettingsOnLaunch {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        coordinator.showSettings()
                    }
                }
            }
        }
        return configuration
    }

    private func registerHotkeys(on coordinator: AppCoordinator) {
        appCoordinator = coordinator
        registerCaptureHotkey(on: coordinator)
        registerBriefHotkey(on: coordinator)
        registerCameraHotkey(on: coordinator)
    }

    private func registerCaptureHotkey(on coordinator: AppCoordinator) {
        let captureID = "peeknook.capture"
        let stored = orchestrator.settings.captureHotkey
        _ = coordinator.hotkeyController.register(
            captureID,
            keyCode: stored.keyCode,
            modifiers: stored.carbonModifiers
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                coordinator.showHome()
                coordinator.showNook()
                self.setup.refreshCapturePermission()
                self.orchestrator.beginCapture()
            }
        }
    }

    private func registerBriefHotkey(on coordinator: AppCoordinator) {
        let briefID = "peeknook.brief"
        let stored = orchestrator.settings.briefHotkey
        _ = coordinator.hotkeyController.register(
            briefID,
            keyCode: stored.keyCode,
            modifiers: stored.carbonModifiers
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                coordinator.showHome()
                coordinator.showNook()
                self.orchestrator.focusBriefComposer()
            }
        }
    }

    private func registerCameraHotkey(on coordinator: AppCoordinator) {
        let cameraID = "peeknook.camera"
        let stored = orchestrator.settings.cameraHotkey
        _ = coordinator.hotkeyController.register(
            cameraID,
            keyCode: stored.keyCode,
            modifiers: stored.carbonModifiers
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                coordinator.showHome()
                coordinator.showNook()
                self.orchestrator.openCameraLive()
            }
        }
    }

    /// Pin the nook open while a phase needs the panel on screen — the post-capture confirm
    /// (`.previewing`) and the live camera (`.cameraLive`) — expanding to Home on entry and
    /// releasing the pin on exit. This loop observes *phase changes only*: collapse/hide are
    /// driven by the configuration's `onCompact`/`onHide` hooks (see `makeConfiguration`), which
    /// cancel the camera and thereby move the phase, after which this loop releases the pin.
    private func startPreviewPhaseHandling(on coordinator: AppCoordinator) {
        previewPhaseTask?.cancel()
        previewPhaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let pinning = context.services.resolve(NookPresentationPinningKey.self)
            enum PinnedPhase { case capturePreview, cameraLive }
            var activePin: PinnedPhase?

            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.orchestrator.phase
                    } onChange: {
                        continuation.resume()
                    }
                }

                let pinned: PinnedPhase?
                switch self.orchestrator.phase {
                case .previewing: pinned = .capturePreview
                case .cameraLive: pinned = .cameraLive
                default: pinned = nil
                }

                if let pinned, pinned != activePin {
                    coordinator.showHome()
                    coordinator.showNook()
                    previewPinHandle?.release()
                    switch pinned {
                    case .capturePreview: previewPinHandle = pinning.pin(reason: "capture-preview")
                    case .cameraLive: previewPinHandle = pinning.pin(reason: "camera-live")
                    }
                } else if pinned == nil, activePin != nil {
                    previewPinHandle?.release()
                    previewPinHandle = nil
                }

                activePin = pinned
            }
        }
    }

    /// `.stayResident` keeps this module alive across module switches — never leave the camera
    /// running, or a live session armed, behind another module's surface.
    public func prepareForSwitchAway() async {
        orchestrator.cancelCameraLive()
        orchestrator.stopLiveSession()
    }
}

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
                conversationArchive: ConversationArchiveStore.makeForTesting()
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
                onCaptureHotkeyChange: { [weak self] _ in
                    guard let self, let coordinator = self.appCoordinator else { return }
                    self.registerHotkeys(on: coordinator)
                },
                onBriefHotkeyChange: { [weak self] _ in
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
        configuration.expandedWidth = 600
        // Seat the in-content command row close to the panel's rounded bottom. The chrome
        // reserves an expanded-content safe-area strip (8pt on three edges by default) that
        // stacks on top of the framework edge padding, leaving a dead band below our last
        // row. Trim just the bottom inset, the command row is centered/leading, so it
        // clears the bottom-corner curve. Radii pin the framework's default appearance.
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

    /// When confirm-before-analyze is on, capture can finish while the nook is still
    /// compact, expand to Home so the preview confirm UI is reachable, and pin the
    /// surface until the user confirms or cancels.
    private func startPreviewPhaseHandling(on coordinator: AppCoordinator) {
        previewPhaseTask?.cancel()
        previewPhaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let pinning = context.services.resolve(NookPresentationPinningKey.self)
            var wasPreviewing = false

            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.orchestrator.phase
                    } onChange: {
                        continuation.resume()
                    }
                }

                let isPreviewing: Bool
                if case .previewing = self.orchestrator.phase {
                    isPreviewing = true
                } else {
                    isPreviewing = false
                }

                if isPreviewing, !wasPreviewing {
                    coordinator.showHome()
                    coordinator.showNook()
                    previewPinHandle?.release()
                    previewPinHandle = pinning.pin(reason: "capture-preview")
                } else if !isPreviewing, wasPreviewing {
                    previewPinHandle?.release()
                    previewPinHandle = nil
                }

                wasPreviewing = isPreviewing
            }
        }
    }
}

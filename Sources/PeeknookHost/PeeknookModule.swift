// SPDX-License-Identifier: Apache-2.0

import Foundation
import NookApp
import PeeknookCore
import PeeknookUI
import SwiftUI

/// Quiet contextual label for the home top bar — breadcrumb drill-ins still win.
private enum PeekTopBarDate {
    nonisolated static func label() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return formatter.string(from: Date())
    }
}

/// Peeknook practice copilot — one module in a multi-module OpenNook host.
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
    private weak var appCoordinator: AppCoordinator?
    private var previewPhaseTask: Task<Void, Never>?
    private var previewPinHandle: NookPresentationPinHandle?

    public init(context: NookModuleContext) {
        self.context = context
        let loaded = PeeknookSettings.load(from: context.defaults)
        let stack = PeeknookServices.makeStack(settings: loaded, defaults: context.defaults)
        self.orchestrator = stack.orchestrator
        self.setup = stack.setup
        self.usage = stack.usage
        self.settings = stack.settings
    }

    public func makeConfiguration() -> NookConfiguration {
        var configuration = NookConfiguration()
        configuration.setHome {
            PeekRootView(
                orchestrator: self.orchestrator,
                setup: self.setup,
                settings: self.settings
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
                usage: self.usage,
                onCaptureHotkeyChange: { [weak self] _ in
                    guard let self, let coordinator = self.appCoordinator else { return }
                    self.registerCaptureHotkey(on: coordinator)
                }
            )
        }
        // Date is ambient home chrome only — drilled-in surfaces (Settings, module
        // breadcrumb) use a stable back label so the route reads "Home › Settings",
        // not "Friday, Jun 5 › Settings".
        configuration.topBar.leadingTitle = { appState in
            let hasBreadcrumb = appState.moduleBreadcrumb?.isEmpty == false
            if appState.isSettingsView || hasBreadcrumb {
                return "Home"
            }
            return PeekTopBarDate.label()
        }
        configuration.topBar.leadingIcon = nil
        configuration.expandedWidth = 480
        configuration.onReady = { [weak self] coordinator in
            self?.registerCaptureHotkey(on: coordinator)
            self?.startPreviewPhaseHandling(on: coordinator)
            // Accessory apps have no main menu, so ⌘A/⌘C/⌘V/⌘X/⌘Z don't reach text fields.
            StandardEditMenu.installIfNeeded()
        }
        return configuration
    }

    private func registerCaptureHotkey(on coordinator: AppCoordinator) {
        appCoordinator = coordinator
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
                if self.setup.isReady {
                    self.orchestrator.beginCapture()
                }
            }
        }
    }

    /// When confirm-before-analyze is on, capture can finish while the nook is still
    /// compact — expand to Home so the preview confirm UI is reachable, and pin the
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

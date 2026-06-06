// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

/// Home is always the root. Setup is a drilled-in sub-screen via ``AppState/moduleBreadcrumb``.
public struct PeekRootView: View {
    public static let setupBreadcrumb = "Get ready"

    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    public var settings: PeekSettingsController

    @EnvironmentObject private var appState: AppState

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        settings: PeekSettingsController
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.settings = settings
    }

    private var showsSetup: Bool {
        appState.moduleBreadcrumb == Self.setupBreadcrumb
    }

    public var body: some View {
        Group {
            if showsSetup {
                PeekSetupView(
                    setup: setup,
                    orchestrator: orchestrator,
                    settings: settings,
                    onContinue: completeOnboarding
                )
            } else {
                PeekHomeView(
                    orchestrator: orchestrator,
                    setup: setup,
                    settings: settings,
                    onOpenSetup: openSetup
                )
            }
        }
        .task { await resolveSetupPresentation() }
        .onChange(of: setup.isReady) { _, ready in
            if ready, showsSetup {
                completeOnboarding()
            }
        }
        .onChange(of: orchestrator.phase) { _, newPhase in
            if case .result = newPhase, setup.isReady {
                setup.markSmokeTestPassed()
            }
        }
    }

    /// Refresh real setup state before routing. Avoids opening setup on launch while steps
    /// are still `.pending` before the first Ollama/permission probe completes.
    private func resolveSetupPresentation() async {
        await setup.refresh()
        if setup.isReady {
            setup.markOnboardingComplete()
            dismissSetup()
        } else if !setup.hasCompletedOnboarding {
            openSetup()
        }
    }

    private func openSetup() {
        appState.moduleBreadcrumb = Self.setupBreadcrumb
    }

    private func completeOnboarding() {
        setup.markOnboardingComplete()
        dismissSetup()
    }

    private func dismissSetup() {
        if appState.moduleBreadcrumb == Self.setupBreadcrumb {
            appState.moduleBreadcrumb = nil
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

/// Home is always the root. Setup is a drilled-in sub-screen via ``AppState/moduleBreadcrumb``.
public struct PeekRootView: View {
    public static let setupBreadcrumb = "Get ready"

    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    public var moduleDefaults: UserDefaults

    @EnvironmentObject private var appState: AppState

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        moduleDefaults: UserDefaults
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.moduleDefaults = moduleDefaults
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
                    onContinue: dismissSetup
                )
            } else {
                PeekHomeView(
                    orchestrator: orchestrator,
                    setup: setup,
                    moduleDefaults: moduleDefaults,
                    onOpenSetup: openSetup
                )
            }
        }
        .onAppear(perform: presentSetupIfNeeded)
        .onChange(of: orchestrator.phase) { _, newPhase in
            if case .result = newPhase, setup.isReady {
                setup.markSmokeTestPassed()
            }
        }
    }

    private func presentSetupIfNeeded() {
        guard !setup.isReady else { return }
        guard appState.moduleBreadcrumb == nil else { return }
        openSetup()
    }

    private func openSetup() {
        appState.moduleBreadcrumb = Self.setupBreadcrumb
    }

    private func dismissSetup() {
        if appState.moduleBreadcrumb == Self.setupBreadcrumb {
            appState.moduleBreadcrumb = nil
        }
    }
}

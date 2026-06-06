// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

public struct PeekCompactView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator

    public init(orchestrator: SessionOrchestrator, setup: SetupCoordinator) {
        self.orchestrator = orchestrator
        self.setup = setup
    }

    public var body: some View {
        Button(action: handleTap) {
            Image(systemName: glyphName)
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.pulse, isActive: isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!setup.isReady && orchestrator.phase == .idle)
        .help(helpText)
    }

    /// idle → capture, failed → retry. Previewing auto-expands via the module; busy/result
    /// phases no-op (capture stays a deliberate, expanded action).
    private func handleTap() {
        switch orchestrator.phase {
        case .idle:
            orchestrator.beginCapture()
        case .failed:
            orchestrator.retryAfterFailure()
        default:
            break
        }
    }

    private var glyphName: String {
        orchestrator.settings.mode.symbolName
    }

    private var isBusy: Bool {
        switch orchestrator.phase {
        case .capturing, .inferring:
            true
        default:
            false
        }
    }

    private var helpText: String {
        switch orchestrator.phase {
        case .idle:
            if setup.isReady {
                "Capture & answer (\(orchestrator.settings.captureHotkey.display))"
            } else {
                "Finish setup first"
            }
        case .capturing:
            "Capturing…"
        case .previewing:
            "Opening preview to confirm"
        case .inferring:
            "Thinking…"
        case .result:
            "Answer ready"
        case .failed(let failure):
            failure.title
        }
    }
}

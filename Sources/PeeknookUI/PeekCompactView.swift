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
        Button {
            guard case .previewing = orchestrator.phase else {
                orchestrator.beginCapture()
                return
            }
        } label: {
            Image(systemName: glyphName)
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.pulse, isActive: isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!setup.isReady && orchestrator.phase == .idle)
        .help(helpText)
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
        case .failed:
            "Capture failed"
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

public struct PeekCompactView: View {
    public var orchestrator: SessionOrchestrator
    public var setup: SetupCoordinator
    /// Expand the nook to Home so the user can read the answer / continue the chat. Wired by the
    /// module to the `AppCoordinator`. Safe: expanding never discards the thread.
    public var onExpand: (() -> Void)?

    public init(
        orchestrator: SessionOrchestrator,
        setup: SetupCoordinator,
        onExpand: (() -> Void)? = nil
    ) {
        self.orchestrator = orchestrator
        self.setup = setup
        self.onExpand = onExpand
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

    /// idle → capture, failed → retry, result → expand to read/continue (no thread loss).
    /// Previewing auto-expands via the module; capturing/inferring no-op (busy).
    private func handleTap() {
        switch orchestrator.phase {
        case .idle:
            orchestrator.beginCapture()
        case .failed:
            orchestrator.retryAfterFailure()
        case .result:
            onExpand?()
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
            "Answer ready, tap to expand"
        case .failed(let failure):
            failure.title
        }
    }
}

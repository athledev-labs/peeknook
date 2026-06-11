// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

struct PeekHomeActiveControls: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var onConfirmPreview: () -> Void
    var onCancel: () -> Void

    var body: some View {
        // Recovery actions live in the PeekFailureView card, so the active bar shows nothing on failure.
        if case .failed = orchestrator.phase {
            EmptyView()
        } else {
            PeekCommandBar(
                placement: .active,
                overrides: orchestrator.resolvedCommandOverrides(for: .active),
                context: CommandBarContext(isPreviewing: isPreviewing, isReady: setup.isReady),
                spacing: 4,
                dispatch: dispatch(_:)
            )
        }
    }

    private var isPreviewing: Bool {
        if case .previewing = orchestrator.phase { return true }
        return false
    }

    private func dispatch(_ action: CommandAction) {
        switch action {
        case .confirmPreview: onConfirmPreview()
        case .cancel:         onCancel()
        default:              break
        }
    }
}

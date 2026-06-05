// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

struct PeekHomeActiveControls: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var onConfirmPreview: () -> Void
    var onCancel: () -> Void
    var onRetryCapture: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            switch orchestrator.phase {
            case .idle:
                EmptyView()
            case .previewing:
                NookToolbarButton(title: "Use this", symbol: "checkmark.circle", prominent: true, action: onConfirmPreview)
                NookToolbarButton(title: "Cancel", symbol: "xmark", action: onCancel)
            case .failed:
                NookToolbarButton(title: "Try again", symbol: "arrow.clockwise", prominent: true, action: onRetryCapture)
                    .disabled(!setup.isReady)
            default:
                NookToolbarButton(title: "Cancel", symbol: "xmark", action: onCancel)
            }
            Spacer(minLength: 0)
        }
    }
}

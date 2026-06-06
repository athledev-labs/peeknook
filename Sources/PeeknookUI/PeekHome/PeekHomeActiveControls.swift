// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

struct PeekHomeActiveControls: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var onConfirmPreview: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            switch orchestrator.phase {
            case .idle:
                EmptyView()
            case .previewing:
                NookToolbarButton(title: "Use this", symbol: "checkmark.circle", prominent: true, action: onConfirmPreview)
                NookToolbarButton(title: "Cancel", symbol: "xmark", action: onCancel)
            case .failed:
                // Recovery actions live in the PeekFailureView card.
                EmptyView()
            default:
                NookToolbarButton(title: "Cancel", symbol: "xmark", action: onCancel)
            }
            Spacer(minLength: 0)
        }
    }
}

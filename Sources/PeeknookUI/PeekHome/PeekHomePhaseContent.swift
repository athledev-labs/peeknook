// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

struct PeekHomePhaseContent: View {
    var orchestrator: SessionOrchestrator
    var showsFullConversation: Bool
    var canRetry: Bool = true
    var onRecover: (RecoveryAction) -> Void = { _ in }

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        switch orchestrator.phase {
        case .idle:
            EmptyView()
        case .capturing:
            VStack(alignment: .leading, spacing: 8) {
                StageLabel(text: "Capturing the screen…", symbol: "camera.viewfinder")
                AnalyzingSkeleton()
            }
        case .previewing(let preview):
            previewContent(preview)
        case .inferring:
            inferringContent
        case .result:
            EmptyView()
        case .failed(let failure):
            PeekFailureView(
                failure: failure,
                canRetry: canRetry,
                usesRemoteOllama: orchestrator.settings.usesRemoteOllama,
                onRecover: onRecover
            )
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: CapturePreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model will see this")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryLabel)
            Text(preview.targetLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            if let thumb = preview.screenshotBase64.flatMap(CapturePreviewImage.nsImage(from:)) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 180)
                    .background(theme.tertiaryLabel.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.tertiaryLabel.opacity(0.35), lineWidth: 1)
                    )
            } else {
                Label("No preview image, capture may have failed. Try again.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Text(preview.sourceLabel)
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryLabel)
            if !preview.excerpt.isEmpty {
                Text(preview.excerpt)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryLabel)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var inferringContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if orchestrator.streamedAnswer.isEmpty {
                if orchestrator.inferenceModelWasWarm {
                    StageLabel(text: "Reading the screen…", symbol: "viewfinder")
                } else {
                    StageLabel(text: "Loading the model, first run is slower…", symbol: "hourglass")
                }
            } else {
                Label("Answering…", systemImage: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryLabel)
            }
            PeekHomeConversationView(
                orchestrator: orchestrator,
                showsFullConversation: showsFullConversation,
                streaming: true
            )
        }
    }
}

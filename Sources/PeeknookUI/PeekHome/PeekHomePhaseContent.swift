// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
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
        case .capturing, .inferring:
            activeLoadingContent
        case .previewing(let preview):
            previewContent(preview)
        case .cameraLive:
            PeekCameraLiveView(orchestrator: orchestrator)
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
            Text(peek: "Model will see this")
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
                    .accessibilityLabel(Text(peek: "Screenshot preview"))
                    .accessibilityAddTraits(.isImage)
            } else {
                Label("No preview image, capture may have failed. Try again.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
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
        .accessibilityElement(children: .contain)
    }

    /// Capture and inference share one resolver for their honest status line (see
    /// ``PeekSessionLoadingPresentation``). Capturing shows the answer skeleton; inferring streams
    /// the live conversation, which renders its own skeleton/web-lookup table.
    @ViewBuilder
    private var activeLoadingContent: some View {
        if let presentation = PeekSessionLoadingPresentation.resolve(for: orchestrator) {
            VStack(alignment: .leading, spacing: 8) {
                loadingLabel(presentation)
                if case .capturing = orchestrator.phase {
                    AnalyzingSkeleton()
                } else {
                    PeekHomeConversationView(
                        orchestrator: orchestrator,
                        showsFullConversation: showsFullConversation,
                        streaming: true
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func loadingLabel(_ presentation: PeekSessionLoadingPresentation) -> some View {
        if presentation.shimmers {
            StageLabel(text: presentation.label, symbol: presentation.symbol)
        } else {
            Label(presentation.label, systemImage: presentation.symbol)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryLabel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(LocalizedStringKey(presentation.label), bundle: .module))
        }
    }
}

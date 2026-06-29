// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import PeeknookDesign
import SwiftUI

/// The `.captioning` surface: an ephemeral, replace-in-place subtitle view driven entirely by the
/// orchestrator's transient `liveCaption` (the analogue of `activeCameraSession`). It renders a short
/// rolling tail, the line currently streaming a translation, and the source-language "hearing…" cue —
/// a glance, never a transcript. Nothing here is persisted; the surface vanishes the instant the caption
/// disarms. When the active profile opted a caption into remote egress, a distinct "sending to <host>"
/// indicator is shown so the local-by-default contract is never silently broken.
struct PeekCaptionView: View {
    var orchestrator: SessionOrchestrator

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        let caption = orchestrator.liveCaption ?? CaptionState()
        VStack(alignment: .leading, spacing: 8) {
            header(caption)
            transcriptStack(caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .peekTestIdentifier(PeekTestID.captionSurface)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func header(_ caption: CaptionState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryLabel)
                .peekDecorative()
            Text("\(caption.sourceLabel ?? autoLabel) → \(caption.targetLabel)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            if let host = caption.remoteEgressHost {
                Label(remoteLabel(host), systemImage: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func transcriptStack(_ caption: CaptionState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The bounded tail of finalized lines, dimmed — context, not focus.
            ForEach(Array(caption.recentLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(2)
            }
            // The line currently streaming its translation, prominent.
            if !caption.currentLine.isEmpty {
                Text(caption.currentLine)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.primaryLabel)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            // The source-language interim hypothesis, subtle (only while nothing has finalized yet).
            if !caption.hearingPartial.isEmpty {
                Text(caption.hearingPartial)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(2)
            }
            // Honest placeholder before the first segment lands, so the surface isn't blank.
            if caption.recentLines.isEmpty, caption.currentLine.isEmpty, caption.hearingPartial.isEmpty {
                Text(peek: "Listening for audio…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.tertiaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var autoLabel: String { PeekLocalized("Auto") }

    private func remoteLabel(_ host: String) -> String {
        String(format: PeekLocalized("Sending to %@"), host)
    }
}

/// The `.captioning` command bar: a single Stop control. Kept deliberately self-contained (not routed
/// through the command-bar placement system) because the caption surface has exactly one action —
/// `stopCaption()`, the disarm choke point that tears the tap down and returns to idle.
struct PeekCaptionControls: View {
    var orchestrator: SessionOrchestrator

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button {
            orchestrator.stopCaption()
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.primaryLabel)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .peekGlass(cornerRadius: 7, isHovered: isHovered)
        }
        .buttonStyle(.borderless)
        .onHover { isHovered = $0 }
        .peekAction(
            label: PeekLocalized("Stop captions"),
            hint: PeekLocalized("End the live caption session")
        )
    }
}

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
            Spacer(minLength: 6)
            // The live audio meter — honest measured loudness, flat at rest. Decorative: it duplicates the
            // header's presence affordance and carries no text.
            PeekCaptionLevelMeter(level: caption.audioLevel, tint: theme.primaryLabel)
        }
    }

    @ViewBuilder
    private func transcriptStack(_ caption: CaptionState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The bounded tail of finalized translations, dimmed — context, not focus.
            ForEach(Array(caption.recentLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(2)
            }
            // The active line as a SOURCE → TRANSLATION pair: the recognized original shows the instant a
            // segment finalizes (so the surface reads as live), with its translation streaming in beneath.
            if !caption.currentSource.isEmpty || !caption.currentLine.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !caption.currentSource.isEmpty {
                        Text(caption.currentSource)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryLabel)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if !caption.currentLine.isEmpty {
                        Text(caption.currentLine)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.primaryLabel)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    } else if caption.isTranslating {
                        // Source is up; translation is on its way — a subtle cue so the gap reads as
                        // "translating", never "stuck".
                        Text(peek: "Translating…")
                            .font(.system(size: 11))
                            .italic()
                            .foregroundStyle(theme.tertiaryLabel)
                    }
                }
            }
            // The source-language interim hypothesis, subtle — only before the first line has finalized,
            // so it never competes with the live source→translation pair above.
            if caption.currentSource.isEmpty, !caption.hearingPartial.isEmpty {
                Text(caption.hearingPartial)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(2)
            }
            // Honest placeholder before the first segment lands, so the surface isn't blank.
            if caption.recentLines.isEmpty, caption.currentSource.isEmpty,
               caption.currentLine.isEmpty, caption.hearingPartial.isEmpty {
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

/// A compact, honest audio-level meter for the caption header: a short rolling row of bars whose heights
/// track the measured loudness streaming in through `level` (a normalized 0...1 scalar). The rolling
/// history is VIEW-LOCAL — `CaptionState` stays a single scalar, so the ephemeral surface never holds a
/// growing waveform buffer. At rest (silence) `level` is 0 and the bars sit flat: no fake pulse, the bars
/// only move when audio actually does. Decorative — it duplicates the header's listening affordance.
struct PeekCaptionLevelMeter: View {
    var level: Float
    var tint: Color

    private static let barCount = 18
    private static let maxBarHeight: CGFloat = 14
    private static let minBarHeight: CGFloat = 2

    @State private var history: [Float] = Array(repeating: 0, count: PeekCaptionLevelMeter.barCount)

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(tint.opacity(0.3 + 0.7 * Double(value)))
                    .frame(width: 2, height: barHeight(value))
            }
        }
        .frame(height: Self.maxBarHeight, alignment: .center)
        .animation(.linear(duration: 0.08), value: history)
        .onChange(of: level) { _, newValue in
            var next = history
            next.removeFirst()
            next.append(min(max(newValue, 0), 1))
            history = next
        }
        .peekDecorative()
    }

    private func barHeight(_ value: Float) -> CGFloat {
        Self.minBarHeight + (Self.maxBarHeight - Self.minBarHeight) * CGFloat(value)
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

// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

extension View {
    /// Shared confirmation before pulling a vision model via Ollama.
    ///
    /// Presented as an in-notch glass overlay (not a native `confirmationDialog`) so the dimming
    /// scrim stays bounded by the panel instead of dimming the whole notch host window. Apply this
    /// to a surface that fills the panel (Settings/Setup body, Home column) so the card centers and
    /// the scrim covers the content area.
    func peekModelDownloadConfirmation(
        pending: Binding<InferenceModelOption?>,
        onDownload: @escaping (InferenceModelOption) -> Void
    ) -> some View {
        modifier(PeekModelDownloadConfirmationModifier(pending: pending, onDownload: onDownload))
    }
}

private struct PeekModelDownloadConfirmationModifier: ViewModifier {
    @Binding var pending: InferenceModelOption?
    let onDownload: (InferenceModelOption) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if let option = pending {
                PeekConfirmationOverlay(
                    title: "Download \(option.displayName)?",
                    message: confirmationMessage(for: option),
                    confirmTitle: "Download",
                    confirmSymbol: "arrow.down.circle",
                    onConfirm: {
                        onDownload(option)
                        pending = nil
                    },
                    onCancel: { pending = nil }
                )
            }
        }
        .animation(.easeOut(duration: 0.15), value: pending)
    }

    /// For the larger tiers, name the size/speed tradeoff and the leaner alternative so a user isn't
    /// nudged into the biggest download by default. (Informational; the picker is one Cancel away.)
    private func confirmationMessage(for option: InferenceModelOption) -> String {
        var message = option.downloadConfirmationMessage
        if let leaner = TextModelCatalog.leanerAlternative(to: option),
           let big = option.downloadHint, let small = leaner.downloadHint {
            message += " " + PeekLocalized("This is the larger, higher-quality model (\(big)). A faster \(small) option is also available.")
        }
        return message
    }
}

/// Reusable in-notch confirmation: a contained scrim (tap to cancel) behind a centered glass card
/// with Cancel / confirm `NookToolbarButton`s. The scrim fills only the view it overlays, so it
/// never dims the surrounding notch host window.
struct PeekConfirmationOverlay: View {
    let title: String
    let message: String
    var confirmTitle: String
    var confirmSymbol: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @Environment(\.nookResolvedTheme) private var theme

    /// Scrim corner radius. The host clips the panel to its internal `NookShape` (top 19 / bottom 24,
    /// set in `PeeknookModule`) and publishes neither that shape nor its radius to modules, and it
    /// pre-clips this surface to a rectangle inset by the column gutter — so the scrim can't inherit the
    /// panel's rounding or bleed out to it. Tuned by eye to nest just inside the panel's corner instead
    /// of reading as a square patch; this is the one knob to turn if it looks tight or loose.
    private static let scrimCornerRadius: CGFloat = 16

    var body: some View {
        ZStack {
            // Round the scrim to its own (rectangular, gutter-inset) frame — see scrimCornerRadius.
            RoundedRectangle(cornerRadius: Self.scrimCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .contentShape(RoundedRectangle(cornerRadius: Self.scrimCornerRadius, style: .continuous))
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    NookToolbarButton(title: "Cancel", symbol: "xmark", action: onCancel)
                    NookToolbarButton(title: confirmTitle, symbol: confirmSymbol, prominent: true, action: onConfirm)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: 300)
            // An opaque, tone-adaptive card. The material OCCLUDES the content behind (no more
            // bleed-through) and matches the panel's light/dark tone, so the theme's tone-adaptive
            // labels stay readable on both the black notch and the frosted Liquid Glass surface. A
            // hairline crisps the edge and a soft shadow lifts it off the scrim.
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThickMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.subtleStroke.opacity(0.6), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            }
            .padding(16)
        }
        .transition(.opacity)
    }
}

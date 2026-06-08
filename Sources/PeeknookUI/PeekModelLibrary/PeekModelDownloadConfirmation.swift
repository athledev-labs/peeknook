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
                    message: option.downloadConfirmationMessage,
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

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.4))
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
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
            }
            .padding(14)
            .frame(maxWidth: 280)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                    PeekCommandPillGlass(cornerRadius: 12)
                }
            }
            .padding(16)
        }
        .transition(.opacity)
    }
}

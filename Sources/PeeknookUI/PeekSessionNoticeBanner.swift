// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

/// Transient, dismissible note for a one-shot ``SessionNotice`` from the orchestrator (a signal with
/// no phase of its own). Mirrors the chrome of the other home banners; the host auto-clears it after
/// a few seconds and also exposes a manual dismiss.
///
/// Copy here is intentionally un-localized for now, matching the sibling banners — the later
/// localization pass (Tier B) migrates these strings through `Text(peek:)` / `Resources/Localizable.xcstrings`.
struct PeekSessionNoticeBanner: View {
    @Environment(\.nookResolvedTheme) private var theme
    let notice: SessionNotice
    /// Whether the just-replaced chat was persisted (so we can honestly say it's in History).
    let conversationArchived: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)
                    .peekDecorative()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.primaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(Text(verbatim: "\(title). \(message)"))
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                NookToolbarButton(
                    title: "Got it",
                    symbol: "checkmark",
                    help: "Dismiss this note",
                    action: onDismiss
                )
                Spacer(minLength: 0)
            }
            .padding(.leading, 24)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.subtleFill.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1)
        )
    }

    private var symbol: String {
        switch notice {
        case .contextFull: "sparkles"
        case .threadUnavailable: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch notice {
        case .contextFull: "Started a new chat"
        case .threadUnavailable: "Couldn't open that chat"
        }
    }

    private var message: String {
        switch notice {
        case .contextFull:
            conversationArchived
                ? "The previous chat's context window was full, so this began a fresh chat. Your earlier chat is saved in History."
                : "The previous chat's context window was full, so this began a fresh chat."
        case .threadUnavailable:
            "That saved chat is missing or unreadable, so it was removed from your history."
        }
    }
}

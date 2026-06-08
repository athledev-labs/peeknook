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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.primaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                NookToolbarButton(
                    title: "Got it",
                    symbol: "checkmark",
                    help: "Dismiss this note",
                    action: onDismiss
                )
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.subtleFill.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }

    private var symbol: String {
        switch notice {
        case .contextFull: "sparkles"
        }
    }

    private var title: String {
        switch notice {
        case .contextFull: "Started a new chat"
        }
    }

    private var message: String {
        switch notice {
        case .contextFull:
            conversationArchived
                ? "The previous chat's context window was full, so this began a fresh chat. Your earlier chat is saved in History."
                : "The previous chat's context window was full, so this began a fresh chat."
        }
    }
}

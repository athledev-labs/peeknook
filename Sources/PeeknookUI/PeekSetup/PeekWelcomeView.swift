// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

/// The one-screen first-run welcome, shown once before the "Get ready" checklist. Pure orientation
/// — no live probes — so it paints instantly on first launch while `setup.refresh()` runs underneath,
/// and it tells a brand-new, non-technical user what Peeknook does and that setup is a one-time step
/// before confronting them with the install chores. Built entirely from the shared design vocabulary
/// (glass card, theme tokens, `NookToolbarButton`, the `⌘⇧P` keycaps) so it reads as native Peeknook,
/// and it lives inside ``PeekSetupView``'s height-capped scroll, so it self-binds (invariant #4).
struct PeekWelcomeView: View {
    let captureHotkey: CaptureHotkey
    let onContinue: () -> Void
    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        PeekScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .peekDecorative()

                VStack(alignment: .leading, spacing: 6) {
                    Text(peek: "Welcome to Peeknook")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.primaryLabel)
                    Text(peek: "Local AI that reads your screen and answers, right from the notch.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 4) {
                    InlineHotkeyKeycaps(symbols: captureHotkey.displaySymbols, theme: theme)
                    Text(peek: "press to capture your screen and ask about it")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryLabel)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "Press \(captureHotkey.spokenLabel) to capture your screen and ask about it"))

                VStack(alignment: .leading, spacing: 6) {
                    Text(peek: "One-time setup takes a few minutes: a free helper app and a model download. You only do this once.")
                    Text(peek: "Your screen stays on your Mac. Nothing is uploaded unless you turn on web lookup or a remote server.")
                }
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(theme.subtleFill.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.subtleStroke.opacity(0.28), lineWidth: 1)
                )

                HStack {
                    NookToolbarButton(
                        title: "Set up Peeknook",
                        symbol: "arrow.right.circle",
                        prominent: true,
                        size: .setup,
                        action: onContinue
                    )
                    Spacer()
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    }
}

// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

/// Transient, dismissible note for a one-shot ``SessionNotice`` from the orchestrator (a signal with
/// no phase of its own). Mirrors the chrome of the other home banners; the host auto-clears it after
/// a few seconds and also exposes a manual dismiss.
///
/// Copy routes through `Text(peek:)` / `Resources/Localizable.xcstrings`; the combined VoiceOver
/// label localizes each piece via `PeekLocalized` so it stays in sync with the visible text.
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
                    Text(peek: title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.primaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    messageText
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(Text(verbatim: "\(PeekLocalized(.init(title))). \(accessibilityMessage)"))
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
        case .liveRefreshFailed: "arrow.clockwise"
        case .liveEnded: "antenna.radiowaves.left.and.right.slash"
        case .captionEnded: "captions.bubble"
        case .captionRemoteBlocked: "lock.shield"
        case .captionNeedsTargetLanguage: "character.bubble"
        case .secretsRedactedForRemote: "eye.slash"
        case .modelMayNotFitMemory: "memorychip"
        case .modelUnloadedUnderMemoryPressure: "bolt.badge.clock"
        }
    }

    private var title: String {
        switch notice {
        case .contextFull: "Started a new chat"
        case .threadUnavailable: "Couldn't open that chat"
        case .liveRefreshFailed: "Couldn't refresh"
        case .liveEnded: "Live ended"
        case .captionEnded: "Captions ended"
        case .captionRemoteBlocked: "Captions stay on this Mac"
        case .captionNeedsTargetLanguage: "Set a caption language"
        case .secretsRedactedForRemote: "Removed secrets before sending"
        case .modelMayNotFitMemory: "Your Mac's memory is almost full"
        case .modelUnloadedUnderMemoryPressure: "Freed the model to free up RAM"
        }
    }

    /// The visible message as a localized `Text`. The redaction case interpolates the count, so it
    /// renders through a `LocalizedStringKey` format key instead of a static literal.
    private var messageText: Text {
        switch notice {
        case .contextFull:
            Text(peek: conversationArchived
                ? "The previous chat's context window was full, so this began a fresh chat. Your earlier chat is saved in History."
                : "The previous chat's context window was full, so this began a fresh chat.")
        case .threadUnavailable:
            Text(peek: "That saved chat is missing or unreadable, so it was removed from your history.")
        case .liveRefreshFailed:
            Text(peek: "Peeknook couldn't capture the latest screen. The live chat is still on, so you can try Refresh again.")
        case .liveEnded:
            Text(peek: "The live session reached its time limit and turned off. Tap Go live to start watching again.")
        case .captionEnded:
            Text(peek: "The live captions reached their time limit or the audio went quiet, so they turned off. Start captions again whenever you like.")
        case .captionRemoteBlocked:
            Text(peek: "Live captions translate on this Mac by default. The selected model runs on a remote server, so captions didn't start. Choose a local model, or allow remote captions for this profile.")
        case .captionNeedsTargetLanguage:
            Text(peek: "Live captions are translated subtitles, so they need a language to translate into. Set a target language on this profile, then start captions again.")
        case .secretsRedactedForRemote(let count):
            Text(peek: "Removed \(count) likely secrets from the text before sending it to your remote model. Your saved chat keeps the original.")
        case .modelMayNotFitMemory(let needGB, let totalGB, let lighterModel):
            if let lighterModel {
                Text(peek: "Peeknook's AI needs about \(needGB) GB of memory. Your Mac has \(totalGB) GB, but other apps are using most of it right now, so capturing may be slow. Close some apps to free up memory, or switch to a lighter model like \(lighterModel) from the menu at the bottom.")
            } else {
                Text(peek: "Peeknook's AI needs about \(needGB) GB of memory. Your Mac has \(totalGB) GB, but other apps are using most of it right now, so capturing may be slow. Closing apps you aren't using (like extra browser tabs) will free up memory.")
            }
        case .modelUnloadedUnderMemoryPressure:
            Text(peek: "Your Mac was low on RAM, so Peeknook released the model to free it up. Your next capture will take a moment to warm up again.")
        }
    }

    /// The same message resolved to a plain `String` for the combined VoiceOver label.
    private var accessibilityMessage: String {
        switch notice {
        case .contextFull:
            PeekLocalized(conversationArchived
                ? "The previous chat's context window was full, so this began a fresh chat. Your earlier chat is saved in History."
                : "The previous chat's context window was full, so this began a fresh chat.")
        case .threadUnavailable:
            PeekLocalized("That saved chat is missing or unreadable, so it was removed from your history.")
        case .liveRefreshFailed:
            PeekLocalized("Peeknook couldn't capture the latest screen. The live chat is still on, so you can try Refresh again.")
        case .liveEnded:
            PeekLocalized("The live session reached its time limit and turned off. Tap Go live to start watching again.")
        case .captionEnded:
            PeekLocalized("The live captions reached their time limit or the audio went quiet, so they turned off. Start captions again whenever you like.")
        case .captionRemoteBlocked:
            PeekLocalized("Live captions translate on this Mac by default. The selected model runs on a remote server, so captions didn't start. Choose a local model, or allow remote captions for this profile.")
        case .captionNeedsTargetLanguage:
            PeekLocalized("Live captions are translated subtitles, so they need a language to translate into. Set a target language on this profile, then start captions again.")
        case .secretsRedactedForRemote(let count):
            PeekLocalized("Removed \(count) likely secrets from the text before sending it to your remote model. Your saved chat keeps the original.")
        case .modelMayNotFitMemory(let needGB, let totalGB, let lighterModel):
            if let lighterModel {
                PeekLocalized("Peeknook's AI needs about \(needGB) GB of memory. Your Mac has \(totalGB) GB, but other apps are using most of it right now, so capturing may be slow. Close some apps to free up memory, or switch to a lighter model like \(lighterModel) from the menu at the bottom.")
            } else {
                PeekLocalized("Peeknook's AI needs about \(needGB) GB of memory. Your Mac has \(totalGB) GB, but other apps are using most of it right now, so capturing may be slow. Closing apps you aren't using (like extra browser tabs) will free up memory.")
            }
        case .modelUnloadedUnderMemoryPressure:
            PeekLocalized("Your Mac was low on RAM, so Peeknook released the model to free it up. Your next capture will take a moment to warm up again.")
        }
    }
}

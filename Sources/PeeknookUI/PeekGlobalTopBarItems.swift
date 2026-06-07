// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

/// Breadcrumb labels shared between the home surface and the global top-bar items, so the
/// label the chrome shows on drill-in matches the state `PeekHomeView` restores.
enum PeekHomeBreadcrumb {
    /// Expanded view of the *current* thread — contextual; toggled from the result command bar.
    static let history = "History"
    /// The conversation archive — browse/resume *past* chats; global, opened from the top bar.
    static let pastChats = "Past chats"
    /// Lifetime and session usage analytics — global, opened from the top bar.
    static let stats = "Stats"
}

/// Global, always-available app actions for the chrome's trailing top-bar cluster (next to the
/// framework keep-open lock and gear).
///
/// **Command placement rule:** a control belongs at the **top** if it's available regardless of
/// phase *and* doesn't act on the current answer/thread; it belongs at the **bottom** if its
/// availability or meaning depends on the current phase, capture, or thread. "Stats" and "Past
/// chats" (browse the archive) are global, so they live here. Phase/thread-specific actions —
/// Capture, Add, Follow,
/// Done, New chat, the in-thread History toggle, Confirm/Cancel, the per-capture preflight pills —
/// stay in the in-content bottom command bars.
public struct PeekGlobalTopBarItems: View {
    public var orchestrator: SessionOrchestrator

    @EnvironmentObject private var appState: AppState
    @Environment(\.nookResolvedTheme) private var theme
    @State private var isPastChatsHovered = false
    @State private var isStatsHovered = false

    public init(orchestrator: SessionOrchestrator) {
        self.orchestrator = orchestrator
    }

    public var body: some View {
        HStack(spacing: 2) {
            statsButton
            if showsPastChats {
                pastChatsButton
            }
        }
    }

    private var statsButton: some View {
        Button {
            appState.moduleBreadcrumb = PeekHomeBreadcrumb.stats
        } label: {
            HStack(spacing: 5) {
                if isStatsHovered {
                    Text("Stats")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .offset(x: 8)),
                                removal: .opacity.combined(with: .offset(x: 6))
                            )
                        )
                }
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isStatsHovered ? theme.primaryLabel.opacity(0.92) : theme.headerInactiveIcon)
                    .frame(width: 24, height: 24)
                    .background(isStatsHovered ? theme.subtleFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isStatsHovered ? theme.subtleStroke : .clear, lineWidth: 1)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isStatsHovered = $0 }
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isStatsHovered)
        .help("Usage stats on this Mac")
        .peekAction(label: "Stats", hint: "Usage stats on this Mac")
    }

    private var pastChatsButton: some View {
        Button {
                // The top bar can't flip PeekHomeView's local state directly, so drive the home
                // surface through the shared breadcrumb; PeekHomeView opens the archive in response.
                appState.moduleBreadcrumb = PeekHomeBreadcrumb.pastChats
            } label: {
                HStack(spacing: 5) {
                    // Hover-reveal label — mirrors the chrome's leading cluster, which springs its
                    // title in next to the glyph. Reveals leftward (toward the notch gap) so it
                    // doesn't push the framework lock/gear off the right edge.
                    if isPastChatsHovered {
                        Text("Past chats")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(theme.secondaryLabel)
                            .lineLimit(1)
                            .fixedSize()
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .offset(x: 8)),
                                    removal: .opacity.combined(with: .offset(x: 6))
                                )
                            )
                    }
                    // The glyph matches the framework's `HeaderIcon` (lock / gear): a bare icon that
                    // only gains a subtle fill on hover, so at rest it reads as chrome, not "active".
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isPastChatsHovered ? theme.primaryLabel.opacity(0.92) : theme.headerInactiveIcon)
                        .frame(width: 24, height: 24)
                        .background(isPastChatsHovered ? theme.subtleFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isPastChatsHovered ? theme.subtleStroke : .clear, lineWidth: 1)
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isPastChatsHovered = $0 }
            .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isPastChatsHovered)
            .help("Browse and resume past chats")
            .peekAction(label: "Past chats", hint: "Browse and resume past chats")
    }

    /// Past chats only makes sense from the home root (idle) and only when the archive has
    /// something to show; otherwise the cluster stays just the framework lock/gear.
    private var showsPastChats: Bool {
        guard case .idle = orchestrator.phase else { return false }
        return !orchestrator.availableThreads().isEmpty
    }
}

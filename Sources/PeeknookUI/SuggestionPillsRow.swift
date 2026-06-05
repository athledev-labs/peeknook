// SPDX-License-Identifier: Apache-2.0

import NookApp
import SwiftUI

/// Horizontal follow-up suggestions — skeleton while loading, pills with hover when ready.
struct SuggestionPillsRow: View {
    @Environment(\.nookResolvedTheme) private var theme
    let isLoading: Bool
    let suggestions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        Group {
            if isLoading {
                loadingRow
                    .transition(.opacity)
            } else if !suggestions.isEmpty {
                pillsRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: isLoading)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: suggestions)
    }

    private let loadingWidths: [CGFloat] = [118, 142, 104]

    private var loadingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Suggesting next questions…", systemImage: "sparkles")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.tertiaryLabel)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(loadingWidths.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.tertiaryLabel.opacity(0.12))
                            .frame(width: loadingWidths[index], height: 28)
                            .shimmering(bandFraction: 0.45, duration: 1.1)
                    }
                }
            }
        }
    }

    private var pillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    SuggestionPillButton(title: suggestion) {
                        onSelect(suggestion)
                    }
                }
            }
        }
    }
}

private struct SuggestionPillButton: View {
    @Environment(\.nookResolvedTheme) private var theme
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isHovered ? theme.primaryLabel : theme.secondaryLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(theme.primaryLabel.opacity(isHovered ? 0.14 : 0.07))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        theme.primaryLabel.opacity(isHovered ? 0.28 : 0.1),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(isHovered ? 0.2 : 0), radius: isHovered ? 6 : 0, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { isHovered = $0 }
        .help(title)
    }
}

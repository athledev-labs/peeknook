// SPDX-License-Identifier: Apache-2.0

import AppKit
import NookApp
import PeeknookCore
import SwiftUI

/// Curated vision model picker — friendly names instead of raw Ollama tags.
struct PeekSettingsModelPickerRow: View {
    let currentTag: String
    let recommendedTag: String
    let isInstalled: (String) -> Bool
    let onSelect: (InferenceModelOption) -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovering = false

    private var displayName: String {
        TextModelCatalog.displayName(for: currentTag)
    }

    private var detail: String {
        let memory = SystemProfile.current().physicalMemoryGB
        if isInstalled(currentTag) {
            if currentTag == recommendedTag {
                return "Recommended for your Mac (\(memory) GB RAM)"
            }
            return "Installed on this Mac"
        }
        if currentTag == recommendedTag {
            return "Recommended for your Mac (\(memory) GB RAM) · not downloaded yet"
        }
        return "Not downloaded yet"
    }

    var body: some View {
        HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? theme.accent : theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text("Vision model")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(detail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            modelMenu
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
        .onHover { isHovering = $0 }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(PeekPreflightOptions.visionModels) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 6) {
                        Text(option.displayName)
                        if isSelected(option) {
                            Image(systemName: "checkmark")
                        } else if !isInstalled(option.tag) {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isHovering ? theme.accent : theme.primaryLabel.opacity(0.92))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.quaternaryLabel)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.subtleFill.opacity(isHovering ? 0.72 : 0.5), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isHovering ? theme.accent.opacity(0.55) : theme.subtleStroke.opacity(0.4),
                        lineWidth: 1
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func isSelected(_ option: InferenceModelOption) -> Bool {
        OllamaSetupClient.matchesModel(installedNames: [currentTag], wanted: option.tag)
    }
}

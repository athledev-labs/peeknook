// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

/// Curated vision model picker — friendly names instead of raw Ollama tags.
struct PeekSettingsModelPickerRow: View {
    let currentTag: String
    let recommendedTag: String
    let models: [InferenceModelOption]
    let customModels: [CustomModelEntry]
    let isInstalled: (String) -> Bool
    let onSelect: (InferenceModelOption) -> Void
    let onAddCustom: () -> Void

    @Environment(\.nookResolvedTheme) private var theme

    private var displayName: String {
        TextModelCatalog.displayName(for: currentTag, custom: customModels)
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
                .foregroundStyle(theme.headerInactiveIcon)
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

            ValueDropdownPill(symbol: "cpu", title: displayName, help: "Vision model") { close in
                PeekPreflightMenuContent.visionModelHomeMenu(
                    currentTag: currentTag,
                    models: models,
                    isInstalled: isInstalled,
                    onSelect: onSelect,
                    onAddCustom: onAddCustom,
                    close: close
                )
            }
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
    }
}

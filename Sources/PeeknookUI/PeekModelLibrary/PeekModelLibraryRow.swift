// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

enum ModelLibraryVisionState: Equatable {
    case none
    case checking
    case supports
    case textOnly
    case unknown
}

/// One row in the model library, friendly name, tag/size detail, and install/select state.
struct PeekModelLibraryRow: View {
    let option: InferenceModelOption
    let isSelected: Bool
    let isInstalled: Bool
    let isRecommended: Bool
    var visionState: ModelLibraryVisionState = .none
    var isDownloading: Bool = false
    var downloadStatus: String?
    var isActionEnabled: Bool = true
    var trailingOverride: String?
    let onTap: () -> Void
    var onRemove: (() -> Void)?

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onTap) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        titleLine
                        Text(rowSubtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(subtitleColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    trailingBadge
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(rowStroke, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .peekAction(label: accessibilityLabel, hint: accessibilityHint)
            .disabled(isDownloading || !isActionEnabled)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.tertiaryLabel)
                        .frame(width: 22, height: 22)
                        .background(theme.subtleFill.opacity(isHovered ? 0.55 : 0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .peekAction(label: "Remove \(option.displayName)", hint: "Remove from your models")
            }
        }
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(spacing: 4) {
            Text(option.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(titleColor)
            if isRecommended {
                Text(peek: "Recommended")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.accent.opacity(0.14), in: Capsule(style: .continuous))
            }
            visionChip
        }
    }

    @ViewBuilder
    private var visionChip: some View {
        switch visionState {
        case .none:
            EmptyView()
        case .checking:
            Text(peek: "Checking…")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(theme.tertiaryLabel)
        case .supports:
            Text(peek: "Vision")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.green.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12), in: Capsule(style: .continuous))
        case .textOnly:
            Text(peek: "Text-only")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.95))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule(style: .continuous))
        case .unknown:
            Text(peek: "Vision unknown")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(theme.tertiaryLabel)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(theme.subtleFill.opacity(0.5), in: Capsule(style: .continuous))
        }
    }

    private var titleColor: Color {
        if !isActionEnabled { return theme.tertiaryLabel }
        return theme.primaryLabel.opacity(0.95)
    }

    private var subtitleColor: Color {
        if visionState == .textOnly { return Color.orange.opacity(0.85) }
        return theme.tertiaryLabel
    }

    private var rowBackground: Color {
        if !isActionEnabled { return theme.subtleFill.opacity(0.12) }
        if isSelected { return theme.primaryLabel.opacity(0.08) }
        return isHovered ? theme.subtleFill.opacity(0.45) : theme.subtleFill.opacity(0.22)
    }

    private var rowStroke: Color {
        if isSelected { return theme.accent.opacity(0.45) }
        return theme.subtleStroke.opacity(isHovered ? 0.45 : 0.25)
    }

    private var rowSubtitle: String {
        if visionState == .textOnly {
            return "\(option.tag) · Can't read screenshots"
        }
        if isRecommended, let ram = recommendedRAMLine {
            return ram
        }
        var parts = [option.tag]
        if let hint = option.downloadHint { parts.append(hint) }
        return parts.joined(separator: " · ")
    }

    private var recommendedRAMLine: String? {
        let gb = SystemProfile.current().physicalMemoryGB
        var parts = ["Best balance for your Mac (\(gb) GB RAM)"]
        if let hint = option.downloadHint { parts.append(hint) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailingBadge: some View {
        if let trailingOverride {
            Text(trailingOverride)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isActionEnabled ? theme.secondaryLabel : theme.quaternaryLabel)
        } else if isDownloading {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                if let downloadStatus {
                    Text(downloadStatus)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(1)
                }
            }
        } else if isSelected, isInstalled {
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.accent)
                .labelStyle(.titleAndIcon)
        } else if isInstalled {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.secondaryLabel)
        } else {
            Label("Download", systemImage: "arrow.down.circle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.secondaryLabel)
                .labelStyle(.titleAndIcon)
        }
    }

    private var accessibilityLabel: String {
        var parts = [option.displayName]
        if isRecommended { parts.append("recommended") }
        switch visionState {
        case .supports: parts.append("vision")
        case .textOnly: parts.append("text only")
        case .unknown: parts.append("vision unknown")
        default: break
        }
        if isSelected { parts.append("active") }
        else if isInstalled { parts.append("installed") }
        else { parts.append("needs download") }
        return parts.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        if !isActionEnabled { return "This model can't read screenshots" }
        if isDownloading { return "Download in progress" }
        if isInstalled { return "Select this model" }
        return "Download and select this model"
    }
}

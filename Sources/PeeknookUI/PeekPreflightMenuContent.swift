// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

/// Shared menu content for capture preflight controls — Home command bar and Settings
/// rows use the same options, actions, and popover rows.
@MainActor
enum PeekPreflightMenuContent {
    @ViewBuilder
    static func captureScopeHomeMenu(
        current: CaptureScope,
        onSelect: @escaping (CaptureScope) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(PeekPreflightOptions.captureScopes) { option in
            Button {
                onSelect(option)
                close()
            } label: {
                ValueMenuRow(
                    title: option.displayName,
                    subtitle: option.menuDetail,
                    selected: current == option
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    static func answerDepthHomeMenu(
        current: AnswerDepth,
        onSelect: @escaping (Bool) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(PeekPreflightOptions.answerDepths, id: \.rawValue) { option in
            Button {
                onSelect(option.quickMode)
                close()
            } label: {
                ValueMenuRow(
                    title: option.barLabel,
                    subtitle: option.menuDetail,
                    selected: current == option
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    static func visionModelHomeMenu(
        currentTag: String,
        models: [InferenceModelOption],
        isInstalled: @escaping (String) -> Bool,
        onSelect: @escaping (InferenceModelOption) -> Void,
        onBrowseModels: (() -> Void)? = nil,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(models) { option in
            Button {
                onSelect(option)
                close()
            } label: {
                ValueMenuRow(
                    title: option.displayName,
                    subtitle: option.downloadHint ?? option.tag,
                    selected: OllamaSetupClient.matchesModel(
                        installedNames: [currentTag],
                        wanted: option.tag
                    ),
                    needsDownload: !isInstalled(option.tag)
                )
            }
            .buttonStyle(.plain)
        }

        if let onBrowseModels {
            Divider().padding(.vertical, 2)
            Button {
                onBrowseModels()
                close()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Browse models…")
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

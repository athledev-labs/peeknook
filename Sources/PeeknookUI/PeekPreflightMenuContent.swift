// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

/// Shared menu content for capture preflight controls — Home pills and Settings rows
/// use the same options and actions; only presentation differs.
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
    static func captureScopeSettingsMenu(
        current: CaptureScope,
        onSelect: @escaping (CaptureScope) -> Void
    ) -> some View {
        ForEach(PeekPreflightOptions.captureScopes) { option in
            Button {
                onSelect(option)
            } label: {
                Label {
                    Text(option.displayName)
                } icon: {
                    if option == current {
                        Image(systemName: "checkmark")
                    }
                }
            }
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
    static func answerDepthSettingsMenu(
        current: AnswerDepth,
        onSelect: @escaping (Bool) -> Void
    ) -> some View {
        ForEach(PeekPreflightOptions.answerDepths, id: \.rawValue) { option in
            Button {
                onSelect(option.quickMode)
            } label: {
                Label {
                    Text("\(option.barLabel) — \(option.menuDetail)")
                } icon: {
                    if option == current {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    static func visionModelHomeMenu(
        currentTag: String,
        isInstalled: @escaping (String) -> Bool,
        onSelect: @escaping (InferenceModelOption) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(PeekPreflightOptions.visionModels) { option in
            Button {
                onSelect(option)
                close()
            } label: {
                ValueMenuRow(
                    title: option.displayName,
                    subtitle: option.downloadHint,
                    selected: OllamaSetupClient.matchesModel(
                        installedNames: [currentTag],
                        wanted: option.tag
                    ),
                    needsDownload: !isInstalled(option.tag)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

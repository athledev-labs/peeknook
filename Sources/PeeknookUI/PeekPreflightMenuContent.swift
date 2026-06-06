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

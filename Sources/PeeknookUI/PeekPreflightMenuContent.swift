// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

/// Shared menu content for capture preflight controls, Home command bar and Settings
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
    static func captureQualityHomeMenu(
        current: CaptureQuality,
        onSelect: @escaping (CaptureQuality) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(PeekPreflightOptions.captureQualities) { option in
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
    static func inferenceImageReplayHomeMenu(
        current: InferenceImageReplay,
        onSelect: @escaping (InferenceImageReplay) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(PeekPreflightOptions.inferenceImageReplays) { option in
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
    static func visionModelHomeMenu(
        models: [InferenceModelOption],
        isInstalled: @escaping (String) -> Bool,
        isSelected: @escaping (InferenceModelOption) -> Bool,
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
                    selected: isSelected(option),
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

    // MARK: - Live session

    /// How an armed live session grabs a fresh frame: Manual (only on Refresh) or Timer (fixed interval).
    @ViewBuilder
    static func liveRefreshTriggerHomeMenu(
        current: RefreshTrigger,
        onSelect: @escaping (RefreshTrigger) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(RefreshTrigger.allCases, id: \.self) { option in
            Button {
                onSelect(option)
                close()
            } label: {
                ValueMenuRow(
                    title: LiveRefreshLabels.title(option),
                    subtitle: LiveRefreshLabels.detail(option),
                    selected: current == option
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Discrete refresh-interval presets (seconds) for a `.timer` live session — a menu, not a slider,
    /// matching the established preflight idiom. A hand-edited non-preset value persists and just shows
    /// no highlighted row until the user picks a preset.
    @ViewBuilder
    static func liveTimerIntervalHomeMenu(
        current: Double,
        onSelect: @escaping (Double) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(LiveRefreshLabels.intervalPresets, id: \.self) { seconds in
            Button {
                onSelect(seconds)
                close()
            } label: {
                ValueMenuRow(
                    title: LiveRefreshLabels.intervalMenuKey(seconds),
                    subtitle: nil,
                    selected: abs(current - seconds) < 0.001
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// The auto-respond rate-cap floor (seconds) — reuses the same presets/copy as the refresh interval.
    @ViewBuilder
    static func liveRateCapHomeMenu(
        current: Double,
        onSelect: @escaping (Double) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(LiveRefreshLabels.intervalPresets, id: \.self) { seconds in
            Button {
                onSelect(seconds)
                close()
            } label: {
                ValueMenuRow(
                    title: LiveRefreshLabels.intervalMenuKey(seconds),
                    subtitle: nil,
                    selected: abs(current - seconds) < 0.001
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// The mandatory Live auto-disarm cap: Off / 15 / 30 / 60 minutes. "Off" is today's behavior (no
    /// cap); the others bound the armed lifetime by an inactivity timeout the user cannot disable.
    @ViewBuilder
    static func liveMaxArmedHomeMenu(
        current: Double,
        onSelect: @escaping (Double) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        ForEach(LiveRemainingLabel.presetSeconds, id: \.self) { seconds in
            Button {
                onSelect(seconds)
                close()
            } label: {
                ValueMenuRow(
                    title: LiveRemainingLabel.maxArmedMenuKey(seconds),
                    subtitle: nil,
                    selected: abs(current - seconds) < 0.001
                )
            }
            .buttonStyle(.plain)
        }
    }
}

/// Display copy for the live-session refresh controls. Kept in the UI layer (not Core) so `RefreshTrigger`
/// stays a pure persistence enum; all strings route through `Localizable.xcstrings` keys.
enum LiveRefreshLabels {
    static let intervalPresets: [Double] = [2, 5, 10, 30, 60]

    static func title(_ trigger: RefreshTrigger) -> String {
        switch trigger {
        case .manual: return "Manual"
        case .timer:  return "Timer"
        }
    }

    static func detail(_ trigger: RefreshTrigger) -> String {
        switch trigger {
        case .manual: return "Only when you press Refresh"
        case .timer:  return "Capture the latest screen on a fixed interval"
        }
    }

    /// The full-sentence catalog key for the interval menu row (e.g. "Every 5 seconds").
    static func intervalMenuKey(_ seconds: Double) -> String {
        "Every \(Int(seconds)) seconds"
    }

    /// The compact pill value for the Settings row (e.g. "5s").
    static func intervalPillLabel(_ seconds: Double) -> String {
        "\(Int(seconds))s"
    }
}

/// Display copy for the mandatory Live auto-disarm countdown (the "Keep watching" cap). Kept in the UI
/// layer like ``LiveRefreshLabels`` so `LivePolicy` stays a pure model. The verbatim form mirrors the
/// established numeric-label idiom (`intervalPillLabel`): a number plus a short unit, rendered with
/// `Text(verbatim:)` rather than a per-value catalog key. The Settings menu uses whole-sentence
/// localized keys (`maxArmedMenuKey`).
enum LiveRemainingLabel {
    /// Off / 15 / 30 / 60 minutes, in seconds. `0` = off (no cap — today's behavior).
    static let presetSeconds: [Double] = [0, 900, 1800, 3600]

    /// The chip's compact "N min left" / "N sec left" (e.g. "12 min left"). Coarse on purpose — the
    /// countdown is a reassurance, not a stopwatch — so anything ≥ 1 minute rounds UP to whole minutes
    /// (so "1 min left" never silently undercounts to "0 min left" while seconds remain).
    static func compact(_ remaining: TimeInterval) -> String {
        let secs = max(0, remaining)
        if secs < 60 {
            return "\(Int(secs.rounded())) sec left"
        }
        let minutes = Int((secs / 60).rounded(.up))
        return "\(minutes) min left"
    }

    /// The Settings menu row label for a cap preset (a whole-sentence catalog key).
    static func maxArmedMenuKey(_ seconds: Double) -> String {
        switch Int(seconds) {
        case 0: return "Off"
        case 900: return "15 minutes"
        case 1800: return "30 minutes"
        case 3600: return "60 minutes"
        default:
            let minutes = Int((seconds / 60).rounded())
            return "\(minutes) minutes"
        }
    }

    /// The compact Settings pill value for the chosen cap (e.g. "30 min", or "Off").
    static func maxArmedPillLabel(_ seconds: Double) -> String {
        seconds <= 0 ? "Off" : "\(Int((seconds / 60).rounded())) min"
    }
}

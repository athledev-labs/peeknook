// SPDX-License-Identifier: Apache-2.0

import Foundation

// Live-session preferences (arm/refresh/rate/cap) plus the inference image-replay knob.
@MainActor
extension PeekSettingsController {
    /// Opt in to the live-session feature (surfaces the "Go live" command on the result bar).
    public func setLiveEnabled(_ enabled: Bool) {
        guard settings.liveEnabled != enabled else { return }
        update { $0.liveEnabled = enabled }
        // Turning the feature OFF must also disarm any session armed-at-idle via persist-across-Done, so
        // it can't outlive the flag (no Live chip/Stop is reachable once the module is gone). Order is
        // load-bearing: the flag flips OFF first (synchronous `update`), THEN we disarm — so no concurrent
        // re-arm can observe `liveEnabled == true`. `stopLive()` is idempotent (no-op when not armed).
        if !enabled { orchestrator.stopLive() }
    }

    /// Opt in to live captions (surfaces the "Caption" command on the idle bar). Off by default — see
    /// ``PeeknookSettings/captionEnabled``. Turning it OFF stops any armed caption so the tap can't
    /// outlive the flag, with the same load-bearing order as ``setLiveEnabled(_:)``: flip the flag OFF
    /// first (synchronous `update`), THEN tear down — so no concurrent re-arm can observe it still on.
    /// `stopCaption()` is idempotent (no-op when not captioning).
    public func setCaptionEnabled(_ enabled: Bool) {
        guard settings.captionEnabled != enabled else { return }
        update { $0.captionEnabled = enabled }
        if !enabled { orchestrator.stopCaption() }
    }

    /// Opt-in: keep an armed Live session across Done (Resume re-enters the same live chat). Off by
    /// default — see ``PeeknookSettings/livePersistAcrossDone``.
    public func setLivePersistAcrossDone(_ enabled: Bool) {
        guard settings.livePersistAcrossDone != enabled else { return }
        update { $0.livePersistAcrossDone = enabled }
    }

    public func setLiveAutoRespond(_ enabled: Bool) {
        guard settings.liveAutoRespond != enabled else { return }
        update { $0.liveAutoRespond = enabled }
    }

    public func setLiveRefreshTrigger(_ trigger: RefreshTrigger) {
        guard settings.liveRefreshTrigger != trigger else { return }
        update { $0.liveRefreshTriggerRaw = trigger.rawValue }
    }

    public func setLiveTimerInterval(_ seconds: Double) {
        let clamped = max(1, seconds)
        guard settings.liveTimerIntervalSeconds != clamped else { return }
        update { $0.liveTimerIntervalSeconds = clamped }
    }

    public func setLiveRateCap(_ seconds: Double) {
        let clamped = max(1, seconds)
        guard settings.liveRateCapSeconds != clamped else { return }
        update { $0.liveRateCapSeconds = clamped }
    }

    /// The mandatory Live auto-disarm cap (max armed lifetime), in seconds. `0` = off (no cap — today's
    /// behavior). Clamped to ≥ 0. A change is a preference only; the deadline is snapshot at the NEXT
    /// arm (the snapshot-at-arm model, like the interval), so an in-flight session keeps its deadline.
    public func setLiveMaxArmedSeconds(_ seconds: Double) {
        let clamped = max(0, seconds)
        guard settings.liveMaxArmedSeconds != clamped else { return }
        update { $0.liveMaxArmedSeconds = clamped }
    }

    public func setInferenceImageReplay(_ replay: InferenceImageReplay) {
        guard settings.inferenceImageReplay != replay else { return }
        update { $0.inferenceImageReplay = replay }
    }
}

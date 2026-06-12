// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Live Session v1 slice 5: the PURE refresh-scheduler policy. No orchestrator, no clock, no timer —
/// every input is injected, so the whole decision table is deterministic. This is the seam the slice-6
/// timer (and slice-7 auto-respond's pause gate) consume; proving it here means the loop only has to be
/// a thin, correct driver. Inert in slice 5 (no production caller), so the app is byte-identical.
final class LiveRefreshPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func decide(
        armed: Bool = true,
        trigger: RefreshTrigger = .timer,
        pressure: SessionOrchestrator.ContextPressure = .normal,
        interval: TimeInterval = 5,
        sinceSeconds: TimeInterval,
        nowSeconds: TimeInterval
    ) -> LiveRefreshPolicy.Decision {
        LiveRefreshPolicy.decide(
            armed: armed, trigger: trigger, pressure: pressure, interval: interval,
            since: t0.addingTimeInterval(sinceSeconds), now: t0.addingTimeInterval(nowSeconds)
        )
    }

    // MARK: Stop — the loop should tear down

    func testStopsWhenNotArmed() {
        XCTAssertEqual(decide(armed: false, sinceSeconds: 0, nowSeconds: 100), .stop)
    }

    func testStopsWhenTriggerIsManual() {
        XCTAssertEqual(decide(trigger: .manual, sinceSeconds: 0, nowSeconds: 100), .stop)
    }

    // MARK: Park vs sleep — the cadence

    func testParksWhenIntervalElapsed() {
        XCTAssertEqual(decide(interval: 5, sinceSeconds: 0, nowSeconds: 5), .park, "due exactly at the interval")
        XCTAssertEqual(decide(interval: 5, sinceSeconds: 0, nowSeconds: 9), .park, "overdue")
    }

    func testSleepsTheExactResidualWhenNotYetDue() {
        // Grafted rigor: assert the RESIDUAL value, not just the case — 3s elapsed of a 5s interval
        // leaves 2s. A wrong residual would either busy-spin or skip a beat.
        XCTAssertEqual(decide(interval: 5, sinceSeconds: 0, nowSeconds: 3), .sleep(2))
    }

    func testNearDueSleepIsFlooredSoItCannotBusySpin() {
        // 0.01s remaining of a 5s interval would be a sub-tick sleep; the floor lifts it to minSleep.
        if case .sleep(let delay) = decide(interval: 5, sinceSeconds: 0, nowSeconds: 4.99) {
            XCTAssertEqual(delay, LiveRefreshPolicy.minSleep, accuracy: 1e-9)
        } else {
            XCTFail("expected a floored sleep")
        }
    }

    // MARK: Pause-at-critical (the slice-5 core) — only .critical pauses; .high warns but parks

    func testCriticalPressurePausesEvenWhenOverdue() {
        // The deadline is long past, but critical context HOLDS the timer — it must not park.
        XCTAssertEqual(
            decide(pressure: .critical, interval: 5, sinceSeconds: 0, nowSeconds: 100),
            .sleep(LiveRefreshPolicy.pausePollInterval),
            "armed + critical → hold and re-poll, never park"
        )
    }

    func testHighPressureDoesNotPause() {
        // .high is a UI warning, not a hard wall — a park grows no prompt, so an overdue tick still fires.
        XCTAssertEqual(decide(pressure: .high, interval: 5, sinceSeconds: 0, nowSeconds: 6), .park)
        XCTAssertEqual(decide(pressure: .high, interval: 5, sinceSeconds: 0, nowSeconds: 3), .sleep(2))
    }

    func testLivePausedPredicateOnlyCriticalHolds() {
        XCTAssertTrue(LiveRefreshPolicy.livePaused(pressure: .critical))
        XCTAssertFalse(LiveRefreshPolicy.livePaused(pressure: .high), "high is warn-only, not a pause")
        XCTAssertFalse(LiveRefreshPolicy.livePaused(pressure: .normal))
    }

    // MARK: Pause wins over Stop precedence is irrelevant — stop is checked first

    func testNotArmedBeatsCritical() {
        // A disarm mid-pause must tear the loop down, not keep polling.
        XCTAssertEqual(decide(armed: false, pressure: .critical, sinceSeconds: 0, nowSeconds: 100), .stop)
    }
}

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
        nowSeconds: TimeInterval,
        deadlineSeconds: TimeInterval? = nil
    ) -> LiveRefreshPolicy.Decision {
        LiveRefreshPolicy.decide(
            armed: armed, trigger: trigger, pressure: pressure, interval: interval,
            since: t0.addingTimeInterval(sinceSeconds), now: t0.addingTimeInterval(nowSeconds),
            deadline: deadlineSeconds.map { t0.addingTimeInterval($0) }
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

    // MARK: Rate cap (slice 7 auto-respond) — the pure throttle, no clock

    func testFirstAutoResponseFiresImmediately() {
        XCTAssertTrue(LiveRefreshPolicy.autoResponseDue(last: nil, cap: 5, now: t0),
                      "no auto-response yet this armed session → eligible at once")
    }

    func testAutoResponseThrottledWithinCap() {
        XCTAssertFalse(
            LiveRefreshPolicy.autoResponseDue(last: t0, cap: 5, now: t0.addingTimeInterval(4)),
            "4s into a 5s cap → not yet eligible"
        )
    }

    func testAutoResponseDueAtAndAfterTheCapBoundary() {
        XCTAssertTrue(
            LiveRefreshPolicy.autoResponseDue(last: t0, cap: 5, now: t0.addingTimeInterval(5)),
            "the boundary is inclusive, matching decide()'s elapsed >= interval"
        )
        XCTAssertTrue(
            LiveRefreshPolicy.autoResponseDue(last: t0, cap: 5, now: t0.addingTimeInterval(6)),
            "overdue → eligible"
        )
    }

    // MARK: Mandatory auto-disarm deadline (`.expire`) — the WS-2 cap, kept pure with injected times

    func testNoDeadlineNeverExpiresByteIdentical() {
        // The default (no cap, deadline == nil): the policy never returns .expire — proving the cap=0
        // path is byte-identical. A normal due tick still parks; a not-due tick still sleeps.
        XCTAssertEqual(decide(interval: 5, sinceSeconds: 0, nowSeconds: 5, deadlineSeconds: nil), .park)
        XCTAssertEqual(decide(interval: 5, sinceSeconds: 0, nowSeconds: 3, deadlineSeconds: nil), .sleep(2))
    }

    func testExpiresWhenDeadlinePassedForTimerTrigger() {
        XCTAssertEqual(
            decide(interval: 5, sinceSeconds: 0, nowSeconds: 100, deadlineSeconds: 60),
            .expire,
            "now (100) is past the deadline (60) → auto-disarm"
        )
    }

    func testDeadlineBoundaryIsInclusive() {
        XCTAssertEqual(
            decide(interval: 5, sinceSeconds: 0, nowSeconds: 60, deadlineSeconds: 60),
            .expire,
            "now == deadline expires (>= boundary, matching the rest of the policy)"
        )
    }

    func testDoesNotExpireBeforeTheDeadline() {
        // Not yet at the deadline and the interval isn't due either → a normal sleep, never .expire.
        XCTAssertEqual(decide(interval: 5, sinceSeconds: 0, nowSeconds: 3, deadlineSeconds: 60), .sleep(2))
    }

    func testExpireOverridesParkWhenBothAreDue() {
        // The refresh interval is overdue (would .park) AND the deadline has passed — the cap wins, so
        // the loop disarms instead of grabbing one more frame after the timeout.
        XCTAssertEqual(
            decide(interval: 5, sinceSeconds: 0, nowSeconds: 100, deadlineSeconds: 60),
            .expire
        )
    }

    func testExpireOverridesPauseAtCritical() {
        // A passed deadline must end the session even while paused at full context — the cap is the
        // backstop that guarantees a session can never silently outlive its limit, pressure or not.
        XCTAssertEqual(
            decide(pressure: .critical, interval: 5, sinceSeconds: 0, nowSeconds: 100, deadlineSeconds: 60),
            .expire
        )
    }

    func testExpireAppliesToManualTriggerToo() {
        // The cap bounds a MANUAL session as well: with a deadline set, decide() runs for the loop that
        // watches it, and a passed deadline expires a manual-trigger session (not .stop).
        XCTAssertEqual(
            decide(trigger: .manual, sinceSeconds: 0, nowSeconds: 100, deadlineSeconds: 60),
            .expire
        )
    }

    func testManualTriggerWithLiveDeadlineSleepsUntilItNotStop() {
        // A manual session WITH a cap must keep the loop alive to watch the deadline: before the deadline
        // it sleeps toward it (not .stop). Without a cap a manual session still .stops (no loop).
        XCTAssertEqual(
            decide(trigger: .manual, sinceSeconds: 0, nowSeconds: 10, deadlineSeconds: 60),
            .sleep(50),
            "sleeps the remaining 50s toward the deadline"
        )
        XCTAssertEqual(
            decide(trigger: .manual, sinceSeconds: 0, nowSeconds: 10, deadlineSeconds: nil),
            .stop,
            "no cap → a manual session runs no loop, byte-identical"
        )
    }

    func testTimerSleepIsShortenedToANearerDeadline() {
        // The next refresh is 2s away but the deadline is only 1s away — the loop must wake at the
        // deadline to .expire on time, so the sleep shortens to 1s rather than over-sleeping the interval.
        XCTAssertEqual(
            decide(interval: 5, sinceSeconds: 0, nowSeconds: 3, deadlineSeconds: 4),
            .sleep(1)
        )
    }

    func testNotArmedBeatsExpire() {
        // A disarm mid-window tears the loop down rather than emitting .expire (which would re-disarm).
        XCTAssertEqual(
            decide(armed: false, sinceSeconds: 0, nowSeconds: 100, deadlineSeconds: 60),
            .stop
        )
    }
}

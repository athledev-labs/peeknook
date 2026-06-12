// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Live Session v1 slice 1: the `LivePolicy` model + the four tolerant-decoded preference fields +
/// the disarm choke point. Guards that Live is OFF by default and that the new settings can never
/// reset the saved blob (tolerant-decode invariant).
final class LivePolicyTests: XCTestCase {
    // MARK: Model

    func testDefaultPolicyIsManualAndAutoRespondOff() {
        let policy = LivePolicy()
        XCTAssertEqual(policy.refresh, .manual)
        XCTAssertFalse(policy.autoRespond, "the user opts into the chatty path")
        XCTAssertEqual(policy.rateCap, 5)
    }

    func testRefreshTriggerRawValues() {
        XCTAssertEqual(RefreshTrigger.manual.rawValue, "manual")
        XCTAssertEqual(RefreshTrigger.timer.rawValue, "timer")
        XCTAssertNil(RefreshTrigger(rawValue: "screenDiff"), "unknown values do not map")
    }

    // MARK: Settings projection + round-trip

    func testLiveRefreshTriggerProjectionDegradesUnknownToManual() {
        var s = PeeknookSettings()
        XCTAssertEqual(s.liveRefreshTrigger, .manual, "default")
        s.liveRefreshTriggerRaw = "timer"
        XCTAssertEqual(s.liveRefreshTrigger, .timer)
        s.liveRefreshTriggerRaw = "onChange" // a future value this build doesn't know
        XCTAssertEqual(s.liveRefreshTrigger, .manual, "unknown reads back as manual")
    }

    func testRoundTripPreservesLiveFields() throws {
        var s = PeeknookSettings(textModel: "gemma4:e4b")
        s.liveAutoRespond = true
        s.liveRefreshTriggerRaw = "timer"
        s.liveTimerIntervalSeconds = 12
        s.liveRateCapSeconds = 8
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(back.liveAutoRespond)
        XCTAssertEqual(back.liveRefreshTrigger, .timer)
        XCTAssertEqual(back.liveTimerIntervalSeconds, 12)
        XCTAssertEqual(back.liveRateCapSeconds, 8)
    }

    // MARK: Tolerant decode (must never reset the rest of settings)

    func testLegacyBlobMissingLiveKeysDecodesToDefaults() throws {
        let json = """
        {"textModel":"gemma4:e2b","answerBackend":"ollama","webLookupEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: json)
        XCTAssertFalse(decoded.liveAutoRespond)
        XCTAssertEqual(decoded.liveRefreshTrigger, .manual)
        XCTAssertEqual(decoded.liveTimerIntervalSeconds, 5)
        XCTAssertEqual(decoded.liveRateCapSeconds, 5)
        XCTAssertEqual(decoded.textModel, "gemma4:e2b")
        XCTAssertTrue(decoded.webLookupEnabled)
    }

    func testUnknownTriggerAndHandEditedIntervalDoNotReset() throws {
        // A newer build wrote "onChange"; a user hand-edited a sub-second interval. Neither throws.
        let json = """
        {"textModel":"gemma4:e4b","liveRefreshTriggerRaw":"onChange","liveTimerIntervalSeconds":0.1,"webLookupEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: json)
        XCTAssertEqual(decoded.liveRefreshTrigger, .manual, "unknown trigger degrades to manual")
        XCTAssertEqual(decoded.liveTimerIntervalSeconds, 0.1, "stored as-is; clamped only at read time")
        XCTAssertEqual(decoded.textModel, "gemma4:e4b", "surrounding settings survive")
        XCTAssertTrue(decoded.webLookupEnabled)
    }

    // MARK: Live OFF by default + the disarm choke point

    @MainActor
    func testLiveOffByDefaultAndStopIsANoOp() {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
        XCTAssertNil(orchestrator.livePolicy)
        XCTAssertFalse(orchestrator.isLiveArmed)
        XCTAssertNil(orchestrator.lastLiveRefreshAt)
        // Idempotent no-op when nothing is armed — never crashes, stays disarmed.
        orchestrator.stopLiveSession()
        orchestrator.stopLiveSession()
        XCTAssertFalse(orchestrator.isLiveArmed)
    }
}

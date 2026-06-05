// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class UsageStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "peeknook.test.usage"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testRecordAggregatesTokensAndBytes() {
        let store = UsageStore(defaults: freshDefaults())
        let capture = CaptureResult(
            text: nil,
            sourceLabel: "x",
            screenshotBase64: String(repeating: "A", count: 400) // ~300 raw bytes
        )

        store.record(capture: capture, inference: InferenceStats(promptTokens: 100, responseTokens: 50, generationSeconds: 2))
        store.record(capture: capture, inference: InferenceStats(promptTokens: 10, responseTokens: 20, generationSeconds: 1))

        XCTAssertEqual(store.stats.captures, 2)
        XCTAssertEqual(store.stats.promptTokens, 110)
        XCTAssertEqual(store.stats.responseTokens, 70)
        XCTAssertEqual(store.stats.generationSeconds, 3, accuracy: 0.0001)
        XCTAssertEqual(store.stats.imageBytes, 600)
        XCTAssertEqual(store.stats.averageTokensPerSecond, 70.0 / 3.0, accuracy: 0.01)
    }

    func testRecordFollowUpAddsTokensButNotCaptures() {
        let store = UsageStore(defaults: freshDefaults())
        store.record(capture: CaptureResult(text: nil, sourceLabel: "x"),
                     inference: InferenceStats(promptTokens: 10, responseTokens: 5, generationSeconds: 1))
        store.recordFollowUp(inference: InferenceStats(promptTokens: 3, responseTokens: 7, generationSeconds: 2))

        XCTAssertEqual(store.stats.captures, 1, "a follow-up is not a new capture")
        XCTAssertEqual(store.stats.promptTokens, 13)
        XCTAssertEqual(store.stats.responseTokens, 12)
        XCTAssertEqual(store.stats.generationSeconds, 3, accuracy: 0.0001)

        store.recordFollowUp(inference: nil) // no telemetry → no change
        XCTAssertEqual(store.stats.responseTokens, 12)
    }

    func testNilStatsStillCountsCapture() {
        let store = UsageStore(defaults: freshDefaults())
        store.record(capture: CaptureResult(text: nil, sourceLabel: "x"), inference: nil)
        XCTAssertEqual(store.stats.captures, 1)
        XCTAssertEqual(store.stats.responseTokens, 0)
        XCTAssertEqual(store.stats.imageBytes, 0) // no screenshot base64
    }

    func testPersistsAndResets() {
        let defaults = freshDefaults()
        let store = UsageStore(defaults: defaults)
        store.record(capture: CaptureResult(text: nil, sourceLabel: "x"), inference: InferenceStats(responseTokens: 5))

        // A fresh store reads the persisted totals.
        XCTAssertEqual(UsageStore(defaults: defaults).stats.responseTokens, 5)

        store.reset()
        XCTAssertEqual(store.stats.captures, 0)
        XCTAssertEqual(UsageStore(defaults: defaults).stats.responseTokens, 0)
    }

    func testTolerantDecodeKeepsKnownFields() throws {
        let legacy = Data(#"{"captures":5,"responseTokens":42}"#.utf8)
        let stats = try JSONDecoder().decode(UsageStats.self, from: legacy)
        XCTAssertEqual(stats.captures, 5)
        XCTAssertEqual(stats.responseTokens, 42)
        XCTAssertEqual(stats.promptTokens, 0)
    }

    func testCancelledInferenceIsNotRecorded() async {
        let usage = UsageStore(defaults: freshDefaults())
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x"),
            capture: StubCaptureProvider(sampleText: "x"),
            inference: MockInferenceEngine(tokens: ["a", "b", "c", "d"], delayNanoseconds: 60_000_000)
        )
        orchestrator.usage = usage

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 90_000_000) // mid-stream
        orchestrator.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000) // let any stray record land

        XCTAssertEqual(usage.stats.captures, 0, "a cancelled inference must not count as a capture")
    }

    func testCompletedInferenceIsRecorded() async {
        let usage = UsageStore(defaults: freshDefaults())
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x"),
            capture: StubCaptureProvider(sampleText: "x"),
            inference: MockInferenceEngine(tokens: ["a", "b"], delayNanoseconds: 10_000_000)
        )
        orchestrator.usage = usage

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(usage.stats.captures, 1, "a completed inference should be recorded once")
    }
}

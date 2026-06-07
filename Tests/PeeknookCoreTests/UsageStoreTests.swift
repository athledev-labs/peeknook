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

        store.record(capture: capture, inference: InferenceStats(promptTokens: 100, responseTokens: 50, generationSeconds: 2), modelTag: "gemma4:e2b")
        store.record(capture: capture, inference: InferenceStats(promptTokens: 10, responseTokens: 20, generationSeconds: 1), modelTag: "gemma4:e2b")

        XCTAssertEqual(store.stats.captures, 2)
        XCTAssertEqual(store.stats.promptTokens, 110)
        XCTAssertEqual(store.stats.responseTokens, 70)
        XCTAssertEqual(store.stats.generationSeconds, 3, accuracy: 0.0001)
        XCTAssertEqual(store.stats.imageBytes, 600)
        XCTAssertEqual(store.stats.averageTokensPerSecond, 70.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(store.stats.events.count, 2)
        XCTAssertEqual(store.stats.events[0].modelTag, "gemma4:e2b")
        XCTAssertTrue(store.stats.events[0].didCapture)
    }

    func testRecordFollowUpAddsTokensButNotCaptures() {
        let store = UsageStore(defaults: freshDefaults())
        store.record(capture: CaptureResult(text: nil, sourceLabel: "x"),
                     inference: InferenceStats(promptTokens: 10, responseTokens: 5, generationSeconds: 1),
                     modelTag: "gemma4:e4b")
        store.recordFollowUp(inference: InferenceStats(promptTokens: 3, responseTokens: 7, generationSeconds: 2),
                             modelTag: "gemma4:e4b")

        XCTAssertEqual(store.stats.captures, 1, "a follow-up is not a new capture")
        XCTAssertEqual(store.stats.promptTokens, 13)
        XCTAssertEqual(store.stats.responseTokens, 12)
        XCTAssertEqual(store.stats.generationSeconds, 3, accuracy: 0.0001)
        XCTAssertEqual(store.stats.events.count, 2)
        XCTAssertFalse(store.stats.events[1].didCapture)

        store.recordFollowUp(inference: nil, modelTag: "gemma4:e4b") // no telemetry → no change
        XCTAssertEqual(store.stats.responseTokens, 12)
        XCTAssertEqual(store.stats.events.count, 2)
    }

    func testNilStatsStillCountsCapture() {
        let store = UsageStore(defaults: freshDefaults())
        store.record(capture: CaptureResult(text: nil, sourceLabel: "x"), inference: nil, modelTag: "x")
        XCTAssertEqual(store.stats.captures, 1)
        XCTAssertEqual(store.stats.responseTokens, 0)
        XCTAssertEqual(store.stats.imageBytes, 0) // no screenshot base64
        XCTAssertTrue(store.stats.events.isEmpty)
    }

    func testPersistsAndResets() {
        let defaults = freshDefaults()
        let store = UsageStore(defaults: defaults)
        store.record(capture: CaptureResult(text: nil, sourceLabel: "x"),
                     inference: InferenceStats(responseTokens: 5),
                     modelTag: "gemma4:e2b")

        // A fresh store reads the persisted totals.
        XCTAssertEqual(UsageStore(defaults: defaults).stats.responseTokens, 5)
        XCTAssertEqual(UsageStore(defaults: defaults).stats.events.count, 1)

        store.reset()
        XCTAssertEqual(store.stats.captures, 0)
        XCTAssertEqual(UsageStore(defaults: defaults).stats.responseTokens, 0)
        XCTAssertTrue(UsageStore(defaults: defaults).stats.events.isEmpty)
    }

    func testTolerantDecodeKeepsKnownFields() throws {
        let legacy = Data(#"{"captures":5,"responseTokens":42}"#.utf8)
        let stats = try JSONDecoder().decode(UsageStats.self, from: legacy)
        XCTAssertEqual(stats.captures, 5)
        XCTAssertEqual(stats.responseTokens, 42)
        XCTAssertEqual(stats.promptTokens, 0)
        XCTAssertTrue(stats.events.isEmpty)
    }

    func testEventsPruneToMaxCount() {
        let store = UsageStore(defaults: freshDefaults())
        let capture = CaptureResult(text: nil, sourceLabel: "x")
        for i in 0..<(UsageStats.maxEvents + 10) {
            store.record(
                capture: capture,
                inference: InferenceStats(promptTokens: 1, responseTokens: 1, generationSeconds: 0.1),
                modelTag: "gemma4:e2b-\(i)"
            )
        }
        XCTAssertEqual(store.stats.events.count, UsageStats.maxEvents)
        XCTAssertEqual(store.stats.events.last?.modelTag, "gemma4:e2b-\(UsageStats.maxEvents + 9)")
    }

    func testModelSummariesGroupByTag() {
        let store = UsageStore(defaults: freshDefaults())
        let capture = CaptureResult(text: nil, sourceLabel: "x")
        store.record(capture: capture, inference: InferenceStats(promptTokens: 10, responseTokens: 20, generationSeconds: 1), modelTag: "a")
        store.record(capture: capture, inference: InferenceStats(promptTokens: 5, responseTokens: 15, generationSeconds: 1), modelTag: "b")
        store.recordFollowUp(inference: InferenceStats(promptTokens: 3, responseTokens: 7, generationSeconds: 1), modelTag: "a")

        let summaries = store.stats.window(for: .allTime).modelSummaries
        XCTAssertEqual(store.stats.modelTotals.count, 2)
        XCTAssertEqual(summaries.count, 2)
        let a = summaries.first { $0.modelTag == "a" }
        XCTAssertEqual(a?.promptTokens, 13)
        XCTAssertEqual(a?.responseTokens, 27)
        XCTAssertEqual(a?.captures, 1)
        XCTAssertEqual(a?.eventCount, 2)
    }

    func testWindowFiltersByDateRange() throws {
        let store = UsageStore(defaults: freshDefaults())
        let capture = CaptureResult(text: nil, sourceLabel: "x")
        store.record(
            capture: capture,
            inference: InferenceStats(promptTokens: 10, responseTokens: 5, generationSeconds: 1),
            modelTag: "gemma4:e2b"
        )

        let recordedAt = try XCTUnwrap(store.stats.events.first?.recordedAt)
        let sameDay = store.stats.window(for: .today, now: recordedAt)
        XCTAssertEqual(sameDay.captures, 1)
        XCTAssertEqual(sameDay.events.count, 1)

        let nextDay = Calendar.current.date(byAdding: .day, value: 2, to: recordedAt)!
        let later = store.stats.window(for: .today, now: nextDay)
        XCTAssertEqual(later.captures, 0)
        XCTAssertTrue(later.events.isEmpty)
    }

    func testAllTimeKeepsLegacyTotalsWithEvents() {
        var stats = UsageStats(captures: 16, promptTokens: 20_000, responseTokens: 1_000, events: [
            UsageEvent(modelTag: "gemma4:e2b", promptTokens: 500, responseTokens: 50, generationSeconds: 1, didCapture: true),
        ])
        let window = stats.window(for: .allTime)
        XCTAssertEqual(window.captures, 16)
        XCTAssertEqual(window.promptTokens, 20_000)
        XCTAssertEqual(window.events.count, 1)
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
        XCTAssertTrue(usage.stats.events.isEmpty)
    }

    func testCompletedInferenceIsRecorded() async {
        let usage = UsageStore(defaults: freshDefaults())
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e2b"),
            capture: StubCaptureProvider(sampleText: "x"),
            inference: MockInferenceEngine(
                tokens: ["a", "b"],
                delayNanoseconds: 10_000_000,
                completionStats: InferenceStats(promptTokens: 50, responseTokens: 2, generationSeconds: 0.2)
            )
        )
        orchestrator.usage = usage

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(usage.stats.captures, 1, "a completed inference should be recorded once")
        XCTAssertEqual(usage.stats.events.count, 1)
        XCTAssertEqual(usage.stats.events[0].modelTag, "gemma4:e2b")
    }
}

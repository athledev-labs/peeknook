// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The fuser's merge logic driven by two stub children + a controllable clock: audio is the fail-closed
/// contract, screen claims authority when fresh, the unified sequence stays monotonic across sources, and
/// nothing forwards after stop().
final class FusingStreamingTranscriberTests: XCTestCase {

    /// A mutable clock the test advances to exercise the router's freshness windows.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var nowValue: Date
        init(_ start: Date) { nowValue = start }
        var now: Date { lock.withLock { nowValue } }
        func advance(_ seconds: TimeInterval) { lock.withLock { nowValue = nowValue.addingTimeInterval(seconds) } }
    }

    private func collector() -> (handler: @Sendable (TranscriptSegment) -> Void, segments: () -> [TranscriptSegment]) {
        let lock = NSLock()
        var captured: [TranscriptSegment] = []
        let handler: @Sendable (TranscriptSegment) -> Void = { seg in lock.withLock { captured.append(seg) } }
        return (handler, { lock.withLock { captured } })
    }

    func testAudioStartErrorFailsClosed() async {
        let audio = StubStreamingTranscriber(startError: SpeechRecognitionError.onDeviceUnavailable)
        let screen = StubStreamingTranscriber()
        let fuser = FusingStreamingTranscriber(audio: audio, screen: screen)
        do {
            try await fuser.start(plan: CaptionTranscriptionPlan(mode: .transcribe, sourceLocale: Locale(identifier: "ko-KR")), onSegment: { _ in }, onLevel: { _ in })
            XCTFail("expected fail-closed throw")
        } catch {
            XCTAssertEqual(error as? SpeechRecognitionError, .onDeviceUnavailable)
            XCTAssertEqual(screen.startCount, 0, "screen must not start once audio failed closed")
        }
    }

    func testScreenStartFailureLeavesAudioOnly() async throws {
        let audio = StubStreamingTranscriber()
        let screen = StubStreamingTranscriber(startError: CaptureError.failed("no window"))
        let fuser = FusingStreamingTranscriber(audio: audio, screen: screen)
        let sink = collector()

        try await fuser.start(plan: CaptionTranscriptionPlan(mode: .transcribe, sourceLocale: Locale(identifier: "ko-KR")), onSegment: sink.handler, onLevel: { _ in })
        audio.emit(TranscriptSegment(text: "annyeong", isStable: true, sequence: 1))

        XCTAssertEqual(sink.segments().map(\.text), ["annyeong"])
    }

    func testScreenClaimsAuthorityOverAudioWhenFresh() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1000))
        let audio = StubStreamingTranscriber()
        let screen = StubStreamingTranscriber()
        let fuser = FusingStreamingTranscriber(audio: audio, screen: screen, now: { clock.now })
        let sink = collector()

        try await fuser.start(plan: CaptionTranscriptionPlan(mode: .transcribe, sourceLocale: Locale(identifier: "ko-KR")), onSegment: sink.handler, onLevel: { _ in })
        // Screen produces a subtitle -> it becomes authoritative.
        screen.emit(TranscriptSegment(text: "from screen", isStable: true, sequence: 1))
        // An audio segment now is dropped (screen is fresh and authoritative).
        audio.emit(TranscriptSegment(text: "from audio", isStable: true, sequence: 1))

        XCTAssertEqual(sink.segments().map(\.text), ["from screen"])
    }

    func testFallsBackToAudioAfterScreenGoesStale() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1000))
        let audio = StubStreamingTranscriber()
        let screen = StubStreamingTranscriber()
        let fuser = FusingStreamingTranscriber(audio: audio, screen: screen, now: { clock.now })
        let sink = collector()

        try await fuser.start(plan: CaptionTranscriptionPlan(mode: .transcribe, sourceLocale: Locale(identifier: "ko-KR")), onSegment: sink.handler, onLevel: { _ in })
        screen.emit(TranscriptSegment(text: "subtitle", isStable: true, sequence: 1))
        // Subtitles stop; well past the release window, audio takes over.
        clock.advance(CaptionSourcePolicy.screenReleaseWindow + 5)
        audio.emit(TranscriptSegment(text: "spoken", isStable: true, sequence: 1))

        XCTAssertEqual(sink.segments().map(\.text), ["subtitle", "spoken"])
        // Unified sequence is monotonic across the source switch.
        XCTAssertEqual(sink.segments().map(\.sequence), [1, 2])
    }

    func testNothingForwardsAfterStop() async throws {
        let audio = StubStreamingTranscriber()
        let screen = StubStreamingTranscriber()
        let fuser = FusingStreamingTranscriber(audio: audio, screen: screen)
        let sink = collector()

        try await fuser.start(plan: CaptionTranscriptionPlan(mode: .transcribe, sourceLocale: Locale(identifier: "ko-KR")), onSegment: sink.handler, onLevel: { _ in })
        fuser.stop()
        audio.emit(TranscriptSegment(text: "late", isStable: true, sequence: 9))

        XCTAssertTrue(sink.segments().isEmpty)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(screen.stopCount, 1)
    }

    func testAudioLevelPassesThrough() async throws {
        let audio = StubStreamingTranscriber()
        let screen = StubStreamingTranscriber()
        let fuser = FusingStreamingTranscriber(audio: audio, screen: screen)
        let lock = NSLock()
        var levels: [Float] = []

        try await fuser.start(plan: CaptionTranscriptionPlan(mode: .transcribe, sourceLocale: Locale(identifier: "ko-KR")), onSegment: { _ in }) { level in
            lock.withLock { levels.append(level) }
        }
        audio.emitLevel(0.5)
        XCTAssertEqual(lock.withLock { levels }, [0.5])
    }
}

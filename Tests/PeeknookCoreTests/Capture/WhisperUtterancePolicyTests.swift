// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure "chunk on a pause" policy for the Whisper caption engine: when an accumulated buffer is a
/// finished utterance worth a transcribe pass, and which raw transcripts are caption-worthy. Clock-free,
/// so it pins the segmentation/cleanup behavior apart from the device-only WhisperKit tap.
final class WhisperUtterancePolicyTests: XCTestCase {

    // MARK: - decide

    func testSilenceWithoutSpeechNeverFinalizes() {
        // A quiet tap (no voiced audio yet) must emit nothing, however long the silence.
        let decision = WhisperUtterancePolicy.decide(
            hadSpeech: false,
            bufferSeconds: 30,
            secondsSinceVoice: 30
        )
        XCTAssertEqual(decision, .keepListening)
    }

    func testTooShortBufferKeepsListening() {
        let decision = WhisperUtterancePolicy.decide(
            hadSpeech: true,
            bufferSeconds: WhisperUtterancePolicy.minUtteranceSeconds - 0.1,
            secondsSinceVoice: 5
        )
        XCTAssertEqual(decision, .keepListening)
    }

    func testTrailingSilenceFinalizesAFinishedLine() {
        let decision = WhisperUtterancePolicy.decide(
            hadSpeech: true,
            bufferSeconds: 2.0,
            secondsSinceVoice: WhisperUtterancePolicy.silenceFinalizeSeconds
        )
        XCTAssertEqual(decision, .finalize)
    }

    func testActiveSpeechBelowCeilingKeepsListening() {
        let decision = WhisperUtterancePolicy.decide(
            hadSpeech: true,
            bufferSeconds: 3.0,
            secondsSinceVoice: 0.1
        )
        XCTAssertEqual(decision, .keepListening)
    }

    func testHardCeilingFinalizesEvenWithoutAPause() {
        // Continuous speech (no trailing silence) still flushes at the ceiling so the buffer is bounded.
        let decision = WhisperUtterancePolicy.decide(
            hadSpeech: true,
            bufferSeconds: WhisperUtterancePolicy.maxUtteranceSeconds,
            secondsSinceVoice: 0.0
        )
        XCTAssertEqual(decision, .finalize)
    }

    // MARK: - isVoice

    func testVoiceThresholdSeparatesSpeechFromRoomTone() {
        XCTAssertFalse(WhisperUtterancePolicy.isVoice(level: 0.0))
        XCTAssertFalse(WhisperUtterancePolicy.isVoice(level: WhisperUtterancePolicy.voiceLevelThreshold - 0.01))
        XCTAssertTrue(WhisperUtterancePolicy.isVoice(level: WhisperUtterancePolicy.voiceLevelThreshold))
        XCTAssertTrue(WhisperUtterancePolicy.isVoice(level: 0.9))
    }

    // MARK: - cleaned

    func testCleanedKeepsRealCaption() {
        XCTAssertEqual(WhisperUtterancePolicy.cleaned("  Hello there.  "), "Hello there.")
    }

    func testCleanedDropsBlankAndWhitespace() {
        XCTAssertNil(WhisperUtterancePolicy.cleaned(""))
        XCTAssertNil(WhisperUtterancePolicy.cleaned("   \n  "))
    }

    func testCleanedDropsNonSpeechAnnotations() {
        XCTAssertNil(WhisperUtterancePolicy.cleaned("[BLANK_AUDIO]"))
        XCTAssertNil(WhisperUtterancePolicy.cleaned("(music)"))
        XCTAssertNil(WhisperUtterancePolicy.cleaned("[Applause]"))
        XCTAssertNil(WhisperUtterancePolicy.cleaned("  [Laughter] "))
    }

    func testCleanedDropsPunctuationOnlyOutput() {
        XCTAssertNil(WhisperUtterancePolicy.cleaned("..."))
        XCTAssertNil(WhisperUtterancePolicy.cleaned("- -"))
    }

    func testCleanedPreservesLineThatMerelyContainsAParenthetical() {
        // Only a WHOLLY-wrapped annotation is dropped; a real line with an aside survives.
        XCTAssertEqual(
            WhisperUtterancePolicy.cleaned("I saw him (yesterday) leave"),
            "I saw him (yesterday) leave"
        )
    }
}

// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Decode-compat for the answer-backend overlay fields: old payloads keep working, corrupted or
/// future backend strings degrade to Ollama, and `textModel` is always written so an old build
/// downgrading from an OpenAI-compatible setup still resolves a real local model.
final class AnswerBackendMigrationTests: XCTestCase {
    func testOldPayloadWithoutAnswerBackendDefaultsToOllama() throws {
        let legacy = #"{"textModel":"gemma4:e2b","ollamaBaseURL":"http://127.0.0.1:11434"}"#
        let settings = try JSONDecoder().decode(PeeknookSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.answerBackend, .ollama)
        XCTAssertEqual(settings.textModel, "gemma4:e2b")
        XCTAssertEqual(settings.openAICompatibleBaseURL, "")
        XCTAssertEqual(settings.openAICompatibleModelTag, "")
        XCTAssertFalse(settings.acceptInsecureRemoteOpenAICompatible)
    }

    func testCorruptedBackendStringDegradesToOllamaWithoutThrowing() throws {
        let blob = #"{"textModel":"gemma4:e2b","answerBackend":"plaid","openAICompatibleModelTag":"qwen2-vl"}"#
        let settings = try JSONDecoder().decode(PeeknookSettings.self, from: Data(blob.utf8))
        XCTAssertEqual(settings.answerBackend, .ollama, "Unknown backend raw value must degrade, never throw.")
        XCTAssertEqual(settings.openAICompatibleModelTag, "qwen2-vl", "The overlay survives the degrade.")
        XCTAssertEqual(settings.textModel, "gemma4:e2b", "The rest of the blob must not reset.")
    }

    func testNewPayloadRoundTripsBackendAndOverlay() throws {
        var settings = PeeknookSettings()
        settings.answerBackend = .openAICompatible
        settings.openAICompatibleBaseURL = "http://127.0.0.1:1234"
        settings.openAICompatibleModelTag = "qwen2-vl-7b-instruct"
        settings.acceptInsecureRemoteOpenAICompatible = true

        let decoded = try JSONDecoder().decode(
            PeeknookSettings.self, from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.answerBackend, .openAICompatible)
        XCTAssertEqual(decoded.openAICompatibleBaseURL, "http://127.0.0.1:1234")
        XCTAssertEqual(decoded.openAICompatibleModelTag, "qwen2-vl-7b-instruct")
        XCTAssertTrue(decoded.acceptInsecureRemoteOpenAICompatible)
    }

    func testAnswerModelComputedFromTextModelForOllama() {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        XCTAssertEqual(settings.answerModel.backend, .ollama)
        XCTAssertEqual(settings.answerModel.tag, "gemma4:e4b")
    }

    func testAnswerModelComputedFromOverlayForOpenAICompatible() {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        settings.answerBackend = .openAICompatible
        settings.openAICompatibleModelTag = "qwen2-vl-7b-instruct"
        XCTAssertEqual(settings.answerModel.backend, .openAICompatible)
        XCTAssertEqual(settings.answerModel.tag, "qwen2-vl-7b-instruct")
    }

    /// The downgrade guarantee: even with the OpenAI-compatible backend active, the persisted
    /// blob still carries the last Ollama tag under `textModel`, so an old build (which only
    /// reads `textModel`) resolves a real local model.
    func testTextModelStillWrittenWhenBackendIsOpenAICompatible() throws {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e2b"
        settings.answerBackend = .openAICompatible
        settings.openAICompatibleModelTag = "qwen2-vl-7b-instruct"

        let blob = try JSONEncoder().encode(settings)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: blob) as? [String: Any])
        XCTAssertEqual(root["textModel"] as? String, "gemma4:e2b")
        XCTAssertEqual(root["answerBackend"] as? String, "openAICompatible")
    }
}

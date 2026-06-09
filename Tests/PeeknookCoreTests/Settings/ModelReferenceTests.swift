// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class ModelReferenceTests: XCTestCase {
    func testDistinctTagsDoNotMatch() {
        let e2b = ModelReference(backend: .ollama, tag: "gemma4:e2b")
        let e4b = ModelReference(backend: .ollama, tag: "gemma4:e4b")
        XCTAssertFalse(e2b.matches(e4b), "Distinct tags are distinct models.")
    }

    func testSameTagMatchesRegardlessOfCapabilities() {
        let withVision = ModelReference(backend: .ollama, tag: "gemma4:e4b", capabilities: [.vision])
        let bare = ModelReference(backend: .ollama, tag: "gemma4:e4b")
        XCTAssertTrue(withVision.matches(bare), "Identity is (backend, normalizedTag); capabilities are transient.")
    }

    func testBareNameNormalizesToLatest() {
        let bareTag = ModelReference(backend: .ollama, tag: "gemma4")
        let latest = ModelReference(backend: .ollama, tag: "gemma4:latest")
        XCTAssertEqual(bareTag.normalizedTag, "gemma4:latest")
        XCTAssertTrue(bareTag.matches(latest))
    }

    func testWhitespaceTagNormalizes() {
        let padded = ModelReference(backend: .ollama, tag: " gemma4:e4b ")
        XCTAssertEqual(padded.normalizedTag, "gemma4:e4b")
    }

    func testAnswerModelProjectsTextModel() {
        var settings = PeeknookSettings()
        settings.textModel = "gemma4:e4b"
        let reference = settings.answerModel
        XCTAssertEqual(reference.backend, .ollama)
        XCTAssertEqual(reference.tag, "gemma4:e4b")
        XCTAssertTrue(reference.capabilities.isEmpty, "Capabilities are filled live, not projected from settings.")
    }
}

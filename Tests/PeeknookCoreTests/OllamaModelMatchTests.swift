// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class OllamaModelMatchTests: XCTestCase {
    func testDistinctTagsDoNotMatch() {
        // The regression: an installed e2b must NOT satisfy a request for e4b.
        XCTAssertFalse(OllamaSetupClient.matchesModel(installedNames: ["gemma4:e2b"], wanted: "gemma4:e4b"))
        XCTAssertFalse(OllamaSetupClient.matchesModel(installedNames: ["gemma4:e2b"], wanted: "gemma4:26b"))
    }

    func testExactTagMatches() {
        XCTAssertTrue(
            OllamaSetupClient.matchesModel(installedNames: ["gemma4:e2b", "gemma4:e4b"], wanted: "gemma4:e4b")
        )
    }

    func testBareNameResolvesToLatest() {
        XCTAssertTrue(OllamaSetupClient.matchesModel(installedNames: ["gemma4:latest"], wanted: "gemma4"))
        XCTAssertTrue(OllamaSetupClient.matchesModel(installedNames: ["gemma4"], wanted: "gemma4:latest"))
        // Bare request must not match a specific non-latest tag.
        XCTAssertFalse(OllamaSetupClient.matchesModel(installedNames: ["gemma4:e2b"], wanted: "gemma4"))
    }

    func testEmptyAndWhitespace() {
        XCTAssertFalse(OllamaSetupClient.matchesModel(installedNames: [], wanted: "gemma4:e4b"))
        XCTAssertTrue(OllamaSetupClient.matchesModel(installedNames: [" gemma4:e4b "], wanted: "gemma4:e4b"))
    }
}

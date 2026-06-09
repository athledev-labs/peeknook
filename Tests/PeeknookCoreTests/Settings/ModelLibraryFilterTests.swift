// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class ModelLibraryFilterTests: XCTestCase {
    private let options = [
        InferenceModelOption(tag: "gemma4:e2b", displayName: "E2B", provider: "Ollama"),
        InferenceModelOption(tag: "gemma4:e4b", displayName: "E4B", provider: "Ollama"),
        InferenceModelOption(tag: "gemma4:26b", displayName: "26B", provider: "Ollama"),
    ]

    func testEmptyFilterReturnsAllUnchanged() {
        let result = ModelLibraryFilters.apply([], to: options, installedNames: ["gemma4:e4b"])
        XCTAssertEqual(result.map(\.tag), ["gemma4:e2b", "gemma4:e4b", "gemma4:26b"])
    }

    func testInstalledFilterKeepsOnlyInstalled() {
        let result = ModelLibraryFilters.apply([.installed], to: options, installedNames: ["gemma4:e4b"])
        XCTAssertEqual(result.map(\.tag), ["gemma4:e4b"])
    }

    func testInstalledFilterIsTagAware() {
        // The documented regression: an installed e2b must NOT make e4b/26b match.
        let result = ModelLibraryFilters.apply([.installed], to: options, installedNames: ["gemma4:e2b"])
        XCTAssertEqual(result.map(\.tag), ["gemma4:e2b"])
    }

    func testInstalledFilterMatchesBareNameAsLatest() {
        let bareOptions = [InferenceModelOption(tag: "llava", displayName: "LLaVA", provider: "Ollama")]
        let result = ModelLibraryFilters.apply([.installed], to: bareOptions, installedNames: ["llava:latest"])
        XCTAssertEqual(result.map(\.tag), ["llava"])
    }

    func testInstalledFilterEmptyWhenNoneInstalled() {
        let result = ModelLibraryFilters.apply([.installed], to: options, installedNames: [])
        XCTAssertTrue(result.isEmpty)
    }
}

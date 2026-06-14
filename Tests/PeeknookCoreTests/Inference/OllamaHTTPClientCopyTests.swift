// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Shipped (Release) copy must never tell a non-technical user to touch Terminal; the from-source
/// Debug build keeps the `ollama serve` / `brew` hints for contributors. `swift test` runs Debug, so
/// the `#if DEBUG` assertions are what CI exercises by default; the `#else` assertions guard the
/// Release wording when CI runs `-c release`.
final class OllamaHTTPClientCopyTests: XCTestCase {
    func testUnreachableCopyOrientsToTheApp() {
        let copy = OllamaUnreachableCopy.notRunning
        XCTAssertTrue(copy.contains("Open the Ollama app"))
        XCTAssertTrue(copy.contains("connect automatically"))
        #if DEBUG
        XCTAssertTrue(copy.contains("ollama serve"), "Debug build keeps the contributor hint.")
        #else
        XCTAssertFalse(copy.contains("ollama serve"))
        XCTAssertFalse(copy.contains("Terminal"))
        #endif
    }

    func testRunnerMissingFailureCopy() {
        let runner = OllamaHTTPClient.friendlyChatFailure(
            status: 500, ollamaError: "llama-server binary not found")
        XCTAssertTrue(runner.contains("missing its model runner"))
        XCTAssertTrue(runner.contains("ollama.com"))
        #if DEBUG
        XCTAssertTrue(runner.contains("brew reinstall ollama"))
        #else
        XCTAssertFalse(runner.contains("brew"))
        XCTAssertFalse(runner.contains("ollama serve"))
        #endif
    }

    func testGenericHTTPFailureCopy() {
        let generic = OllamaHTTPClient.friendlyChatFailure(status: 500, ollamaError: nil)
        #if DEBUG
        XCTAssertTrue(generic.contains("ollama serve"))
        #else
        XCTAssertFalse(generic.contains("ollama serve"))
        XCTAssertFalse(generic.contains("Terminal"))
        XCTAssertTrue(generic.contains("Open the Ollama app"))
        #endif
    }

    func testRawOllamaErrorBodyStillSurfacesVerbatim() {
        let raw = OllamaHTTPClient.friendlyChatFailure(status: 500, ollamaError: "some weird error")
        XCTAssertTrue(raw.contains("some weird error"),
                      "The real Ollama error body must still reach the user for debugging.")
    }
}

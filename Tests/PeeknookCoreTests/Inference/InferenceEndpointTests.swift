// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class InferenceEndpointTests: XCTestCase {
    func testConnectionExtractsBaseURLAndInsecureForBothBackends() {
        let ollama = InferenceEndpoint.ollama(
            baseURL: "http://127.0.0.1:11434",
            acceptInsecureRemote: false
        )
        XCTAssertEqual(ollama.connection.baseURL, "http://127.0.0.1:11434")
        XCTAssertFalse(ollama.connection.acceptInsecureRemote)

        let openAI = InferenceEndpoint.openAICompatible(
            baseURL: "http://127.0.0.1:1234",
            apiKeyRef: .openAICompatiblePrimary,
            acceptInsecureRemote: true
        )
        XCTAssertEqual(openAI.connection.baseURL, "http://127.0.0.1:1234")
        XCTAssertTrue(openAI.connection.acceptInsecureRemote)
    }

    func testBackendComputedMatchesCase() {
        XCTAssertEqual(
            InferenceEndpoint.ollama(baseURL: "x", acceptInsecureRemote: false).backend,
            .ollama
        )
        XCTAssertEqual(
            InferenceEndpoint.openAICompatible(
                baseURL: "x", apiKeyRef: .openAICompatiblePrimary, acceptInsecureRemote: false
            ).backend,
            .openAICompatible
        )
    }

    /// Equality is identity of the *ref*, never key material — two endpoints with the same ref id
    /// are equal whatever the Keychain holds; a different base URL breaks equality.
    func testEndpointEquatableComparesRefNotKeyMaterial() {
        let a = InferenceEndpoint.openAICompatible(
            baseURL: "http://127.0.0.1:1234",
            apiKeyRef: .openAICompatiblePrimary,
            acceptInsecureRemote: false
        )
        let b = InferenceEndpoint.openAICompatible(
            baseURL: "http://127.0.0.1:1234",
            apiKeyRef: .openAICompatiblePrimary,
            acceptInsecureRemote: false
        )
        let otherURL = InferenceEndpoint.openAICompatible(
            baseURL: "http://127.0.0.1:8000",
            apiKeyRef: .openAICompatiblePrimary,
            acceptInsecureRemote: false
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, otherURL)
    }

    func testFromSettingsStillResolvesOllama() {
        var settings = PeeknookSettings()
        settings.ollamaBaseURL = "http://127.0.0.1:11434"
        let endpoint = InferenceEndpoint.from(settings: settings)
        XCTAssertEqual(endpoint.backend, .ollama)
    }
}

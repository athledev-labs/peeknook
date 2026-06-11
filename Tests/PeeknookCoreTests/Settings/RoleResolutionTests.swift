// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure role → (model, endpoint) resolver, plus the tolerant-decode contract for the three new
/// text-only routing settings. Guards the byte-identical default and the no-reset-on-decode invariant.
final class RoleResolutionTests: XCTestCase {
    private func settingsFixture() -> PeeknookSettings {
        var s = PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b")
        s.openAICompatibleBaseURL = "http://127.0.0.1:1234"
        return s
    }

    // MARK: Resolver

    func testEveryRoleResolvesPrimaryVisionPairWhenTextOnlyUnset() {
        let s = settingsFixture() // textOnlyModelTag == "" (default)
        let primary = RoleResolution(
            model: s.answerModel(for: .screenDefault),
            endpoint: s.endpoint(for: .screenDefault)
        )
        for role in ModelRole.allCases {
            XCTAssertEqual(
                s.resolved(role: role, for: .screenDefault), primary,
                "Role \(role) must resolve the primary vision pair until a real binding exists."
            )
        }
    }

    func testTextOnlyResolvesOllamaOverlayWhenConfigured() {
        var s = settingsFixture()
        s.textOnlyBackend = .ollama
        s.textOnlyModelTag = "qwen2.5:0.5b"
        let route = s.resolved(role: .textOnly, for: .screenDefault)
        XCTAssertEqual(route.model.tag, "qwen2.5:0.5b")
        XCTAssertEqual(route.model.backend, .ollama)
        XCTAssertEqual(route.endpoint.backend, .ollama)
        // Other roles stay on the vision model even with a text model configured.
        XCTAssertEqual(s.resolved(role: .primaryVision, for: .screenDefault).model.tag, "gemma4:e4b")
    }

    func testTextOnlyResolvesOpenAIEndpointAndKeyRef() {
        var s = settingsFixture()
        s.textOnlyBackend = .openAICompatible
        s.textOnlyModelTag = "local-mini"
        let route = s.resolved(role: .textOnly, for: .screenDefault)
        XCTAssertEqual(route.model.backend, .openAICompatible)
        XCTAssertEqual(
            route.endpoint,
            .openAICompatible(
                baseURL: "http://127.0.0.1:1234",
                apiKeyRef: .openAICompatiblePrimary,
                acceptInsecureRemote: false
            ),
            "The text-only model must ship to its own backend's server through the same HTTPS gate."
        )
    }

    func testUnconfiguredTextOnlyFallsBackToPrimaryVision() {
        let s = settingsFixture() // tag empty
        XCTAssertFalse(s.hasUsableTextOnlyModel)
        XCTAssertNil(s.textOnlyModel)
        XCTAssertEqual(
            s.resolved(role: .textOnly, for: .screenDefault),
            s.resolved(role: .primaryVision, for: .screenDefault)
        )
    }

    func testWhitespaceOnlyTagIsNotUsable() {
        var s = settingsFixture()
        s.textOnlyModelTag = "   "
        XCTAssertFalse(s.hasUsableTextOnlyModel)
        XCTAssertNil(s.textOnlyModel)
    }

    // MARK: Tolerant decode (must never reset the rest of settings)

    func testUnknownTextOnlyBackendDegradesToOllamaWithoutResetting() throws {
        let json = """
        {"textModel":"gemma4:e4b","answerBackend":"ollama","textOnlyBackend":"sidecar",
         "textOnlyModelTag":"qwen2.5:0.5b","fastTextFollowUps":true,"webLookupEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: json)
        XCTAssertEqual(decoded.textOnlyBackend, .ollama, "Unknown backend degrades, never throws.")
        // The surrounding settings survive (no full reset bomb).
        XCTAssertEqual(decoded.textModel, "gemma4:e4b")
        XCTAssertEqual(decoded.textOnlyModelTag, "qwen2.5:0.5b")
        XCTAssertTrue(decoded.fastTextFollowUps)
        XCTAssertTrue(decoded.webLookupEnabled)
    }

    func testLegacyBlobMissingNewKeysDecodesToDefaults() throws {
        // A blob written by a pre-router build has none of the three keys.
        let json = """
        {"textModel":"gemma4:e2b","answerBackend":"ollama","webLookupEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: json)
        XCTAssertFalse(decoded.fastTextFollowUps)
        XCTAssertEqual(decoded.textOnlyBackend, .ollama)
        XCTAssertEqual(decoded.textOnlyModelTag, "")
        XCTAssertEqual(decoded.textModel, "gemma4:e2b")
        XCTAssertTrue(decoded.webLookupEnabled)
        // Default ⇒ byte-identical routing: textOnly resolves the primary vision pair.
        XCTAssertEqual(
            decoded.resolved(role: .textOnly, for: .screenDefault),
            decoded.resolved(role: .primaryVision, for: .screenDefault)
        )
    }

    func testRoundTripPreservesNewFields() throws {
        var s = settingsFixture()
        s.fastTextFollowUps = true
        s.textOnlyBackend = .openAICompatible
        s.textOnlyModelTag = "local-mini"
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: data)
        XCTAssertTrue(back.fastTextFollowUps)
        XCTAssertEqual(back.textOnlyBackend, .openAICompatible)
        XCTAssertEqual(back.textOnlyModelTag, "local-mini")
        XCTAssertEqual(back.textModel, s.textModel, "textModel is always written (downgrade safety).")
    }
}

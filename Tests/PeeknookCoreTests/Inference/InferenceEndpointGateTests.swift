// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The HTTPS / loopback gate (``EndpointURLPolicy``) reached through the single
/// ``InferenceEndpoint/resolvedBaseURL()`` accessor every engine now uses. These tests pin the
/// invariant M2 establishes: an inference endpoint can become a usable URL only through the gate, so
/// no construction site — global, per-profile binding, or a future per-role binding — can reach the
/// network on plain HTTP to a remote host without the explicit opt-in.
final class InferenceEndpointGateTests: XCTestCase {
    private func assertInferenceError(
        _ expected: InferenceError,
        _ expression: @autoclosure () throws -> URL,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            guard let actual = error as? InferenceError else {
                return XCTFail("expected InferenceError, got \(error). \(message)", file: file, line: line)
            }
            switch (actual, expected) {
            case (.insecureRemoteHTTP, .insecureRemoteHTTP), (.invalidBaseURL, .invalidBaseURL):
                break
            default:
                XCTFail("expected \(expected), got \(actual). \(message)", file: file, line: line)
            }
        }
    }

    // MARK: - The gate, reached through resolvedBaseURL()

    func testLoopbackHTTPAlwaysResolves() throws {
        // 127.0.0.1 / localhost / ::1 are the local daemon: plain HTTP is fine, no opt-in needed.
        for host in ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"] {
            let url = try InferenceEndpoint.ollama(baseURL: host, acceptInsecureRemote: false).resolvedBaseURL()
            XCTAssertEqual(url.absoluteString, host)
        }
    }

    func testRemoteHTTPSResolvesWithoutOptIn() throws {
        let url = try InferenceEndpoint.ollama(
            baseURL: "https://ollama.example.com", acceptInsecureRemote: false
        ).resolvedBaseURL()
        XCTAssertEqual(url.absoluteString, "https://ollama.example.com")
    }

    func testRemoteHTTPThrowsWithoutOptIn() {
        // The core gate: plain HTTP to a non-loopback host is refused unless the user opted in.
        assertInferenceError(
            .insecureRemoteHTTP,
            try InferenceEndpoint.ollama(baseURL: "http://ollama.example.com:11434", acceptInsecureRemote: false).resolvedBaseURL(),
            "a remote plain-HTTP endpoint must be refused without the opt-in"
        )
        assertInferenceError(
            .insecureRemoteHTTP,
            try InferenceEndpoint.openAICompatible(
                baseURL: "http://lan-box.local:1234", apiKeyRef: .openAICompatiblePrimary, acceptInsecureRemote: false
            ).resolvedBaseURL(),
            "the gate is backend-neutral: OpenAI-compatible is gated identically"
        )
    }

    func testRemoteHTTPResolvesWithOptIn() throws {
        let url = try InferenceEndpoint.ollama(
            baseURL: "http://ollama.example.com:11434", acceptInsecureRemote: true
        ).resolvedBaseURL()
        XCTAssertEqual(url.absoluteString, "http://ollama.example.com:11434")
    }

    func testUnusableURLThrowsInvalidBaseURL() {
        for bad in ["", "   ", "not a url", "ftp://example.com"] {
            assertInferenceError(
                .invalidBaseURL,
                try InferenceEndpoint.ollama(baseURL: bad, acceptInsecureRemote: true).resolvedBaseURL(),
                "“\(bad)” is not a usable http(s) inference URL"
            )
        }
    }

    // MARK: - Every construction site funnels through the same gate

    private func userProfile(binding: ProfileModelBinding?) -> GroundProfile {
        GroundProfile(
            id: "u1", displayNameKey: "Screen", symbol: "macwindow",
            primaryGround: .screen, activeGrounds: [.screen], isBuiltIn: false,
            displayName: "Bound", modelBinding: binding
        )
    }

    func testActiveTextOnlyAndProfileEndpointsAllRouteThroughTheGate() {
        // A remote plain-HTTP Ollama with the opt-in OFF: the gate must bite no matter which endpoint
        // the turn resolves to — the global active endpoint, the routed text-only endpoint, or a
        // per-profile binding's endpoint. None may bypass it.
        var settings = PeeknookSettings()
        settings.ollamaBaseURL = "http://remote.example.com:11434"
        settings.acceptInsecureRemoteOllama = false

        let profile = userProfile(binding: ProfileModelBinding(backend: .ollama, tag: "gemma4:e4b"))

        assertInferenceError(.insecureRemoteHTTP, try settings.activeEndpoint.resolvedBaseURL(),
                             "the global active endpoint is gated")
        assertInferenceError(.insecureRemoteHTTP, try settings.textOnlyEndpoint.resolvedBaseURL(),
                             "the routed text-only endpoint is gated identically")
        assertInferenceError(.insecureRemoteHTTP, try settings.endpoint(for: profile).resolvedBaseURL(),
                             "a per-profile binding's endpoint cannot bypass the gate")
    }

    func testProfileBindingEndpointResolvesOnceOptedIn() throws {
        // The same per-profile binding succeeds the moment the user opts into insecure remote HTTP,
        // proving the opt-in is the only thing standing between the binding and the network.
        var settings = PeeknookSettings()
        settings.ollamaBaseURL = "http://remote.example.com:11434"
        settings.acceptInsecureRemoteOllama = true
        let profile = userProfile(binding: ProfileModelBinding(backend: .ollama, tag: "gemma4:e4b"))
        let url = try settings.endpoint(for: profile).resolvedBaseURL()
        XCTAssertEqual(url.absoluteString, "http://remote.example.com:11434")
    }

    func testOpenAICompatibleProfileBindingEndpointIsGated() {
        // The other per-profile construction site: an .openAICompatible binding derives its endpoint
        // from the OpenAI-compatible server fields, and the gate bites it identically.
        var settings = PeeknookSettings()
        settings.openAICompatibleBaseURL = "http://lan-box.local:1234"
        settings.acceptInsecureRemoteOpenAICompatible = false
        let profile = userProfile(binding: ProfileModelBinding(backend: .openAICompatible, tag: "qwen2-vl"))
        assertInferenceError(
            .insecureRemoteHTTP, try settings.endpoint(for: profile).resolvedBaseURL(),
            "an .openAICompatible per-profile binding's endpoint cannot bypass the gate either"
        )
    }
}

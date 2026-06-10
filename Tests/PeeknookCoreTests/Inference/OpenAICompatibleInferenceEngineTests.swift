// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PeeknookCore

/// Exercises the OpenAI-compatible engine against a stubbed URL session (no network), reusing
/// `OllamaURLProtocolStub` — the stub is transport-generic.
@MainActor
final class OpenAICompatibleInferenceEngineTests: XCTestCase {
    private let baseURL = "http://127.0.0.1:1234"

    override func setUp() {
        OllamaURLProtocolStub.responsesByPath = [:]
        OllamaURLProtocolStub.recordedBodies = []
        OllamaURLProtocolStub.recordedAuthorizationHeaders = []
    }

    private func makeEngine(
        resolveAPIKey: @escaping @Sendable (CredentialRef) -> String? = { _ in nil }
    ) -> OpenAICompatibleInferenceEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaURLProtocolStub.self]
        return OpenAICompatibleInferenceEngine(
            session: URLSession(configuration: config),
            resolveAPIKey: resolveAPIKey
        )
    }

    private func makeRequest(
        text: String = "What is on screen?",
        imageBase64: String? = nil,
        quickMode: Bool = false
    ) -> InferenceRequest {
        InferenceRequest(
            mode: .general,
            messages: [InferenceMessage(role: .user, text: text, imageBase64: imageBase64)],
            model: "qwen2-vl-7b-instruct",
            endpoint: .openAICompatible(
                baseURL: baseURL,
                apiKeyRef: .openAICompatiblePrimary,
                acceptInsecureRemote: false
            ),
            quickMode: quickMode
        )
    }

    private func queueChatStream(_ sse: String, status: Int = 200) {
        OllamaURLProtocolStub.responsesByPath["/v1/chat/completions"] = [
            .init(statusCode: status, body: Data(sse.utf8), headers: [:])
        ]
    }

    private func collectEvents(_ request: InferenceRequest) async throws -> [InferenceEvent] {
        var events: [InferenceEvent] = []
        for try await event in makeEngine().stream(request: request) {
            events.append(event)
        }
        return events
    }

    // MARK: - Streaming

    func testStreamParsesSSEDeltasIntoTokens() async throws {
        queueChatStream("""
        data: {"choices":[{"delta":{"content":"Hel"}}]}
        data: {"choices":[{"delta":{"content":"lo"}}]}
        data: [DONE]
        """)
        let events = try await collectEvents(makeRequest())
        XCTAssertEqual(events, [.token("Hel"), .token("lo"), .completed(nil)])
    }

    func testStreamUsageChunkMapsToInferenceStats() async throws {
        queueChatStream("""
        data: {"choices":[{"delta":{"content":"hi"}}]}
        data: {"choices":[],"usage":{"prompt_tokens":42,"completion_tokens":7}}
        data: [DONE]
        """)
        let events = try await collectEvents(makeRequest())
        XCTAssertEqual(events, [
            .token("hi"),
            .completed(InferenceStats(promptTokens: 42, responseTokens: 7, generationSeconds: 0)),
        ])
    }

    func testStreamWithoutDoneSentinelStillCompletes() async throws {
        queueChatStream("""
        data: {"choices":[{"delta":{"content":"partial"}}]}
        """)
        let events = try await collectEvents(makeRequest())
        XCTAssertEqual(events, [.token("partial"), .completed(nil)])
    }

    func testStreamRetriesOnceWithoutStreamOptionsWhenServerRejectsThem() async throws {
        OllamaURLProtocolStub.responsesByPath["/v1/chat/completions"] = [
            .init(
                statusCode: 400,
                body: Data(#"{"error":{"message":"unknown field stream_options"}}"#.utf8),
                headers: [:]
            ),
            .init(statusCode: 200, body: Data("""
            data: {"choices":[{"delta":{"content":"ok"}}]}
            data: [DONE]
            """.utf8), headers: [:]),
        ]
        let events = try await collectEvents(makeRequest())
        XCTAssertEqual(events, [.token("ok"), .completed(nil)])
        XCTAssertEqual(OllamaURLProtocolStub.recordedBodies.count, 2)
        let retryBody = try XCTUnwrap(OllamaURLProtocolStub.recordedBodies.last)
        XCTAssertFalse(
            String(data: retryBody, encoding: .utf8)!.contains("stream_options"),
            "The retry must drop stream_options."
        )
    }

    func testNon200MapsToHTTPErrorReadingErrorBody() async {
        queueChatStream(#"{"error":{"message":"model exploded"}}"#, status: 500)
        do {
            _ = try await collectEvents(makeRequest())
            XCTFail("Expected an InferenceError.http throw")
        } catch let InferenceError.http(status, message) {
            XCTAssertEqual(status, 500)
            XCTAssertTrue(message.contains("model exploded"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInsecureRemoteHTTPRejectedBeforeAnyRequest() async {
        let request = InferenceRequest(
            mode: .general,
            messages: [InferenceMessage(role: .user, text: "hi")],
            model: "m",
            endpoint: .openAICompatible(
                baseURL: "http://192.168.1.50:1234",
                apiKeyRef: .openAICompatiblePrimary,
                acceptInsecureRemote: false
            )
        )
        do {
            _ = try await collectEvents(request)
            XCTFail("Expected insecureRemoteHTTP")
        } catch let error as InferenceError {
            guard case .insecureRemoteHTTP = error else {
                return XCTFail("Expected insecureRemoteHTTP, got \(error)")
            }
            XCTAssertTrue(
                OllamaURLProtocolStub.recordedBodies.isEmpty,
                "The HTTPS gate must reject before any bytes leave the process."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Request body shape

    func testThinkFieldNeverSentInBody() async throws {
        queueChatStream("data: [DONE]")
        _ = try await collectEvents(makeRequest())
        let body = try XCTUnwrap(OllamaURLProtocolStub.recordedBodies.first)
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("\"think\""))
    }

    func testTextOnlyMessageUsesPlainStringContent() async throws {
        queueChatStream("data: [DONE]")
        _ = try await collectEvents(makeRequest(text: "plain question"))
        let body = try XCTUnwrap(OllamaURLProtocolStub.recordedBodies.first)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["content"] as? String, "plain question")
    }

    func testImageMessageMapsToContentArrayWithDataURL() async throws {
        queueChatStream("data: [DONE]")
        _ = try await collectEvents(makeRequest(imageBase64: "QUJD"))
        let body = try XCTUnwrap(OllamaURLProtocolStub.recordedBodies.first)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        let imagePart = try XCTUnwrap(content.last)
        XCTAssertEqual(imagePart["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/jpeg;base64,QUJD")
    }

    func testMultipleImagesMapToMultipleImageURLParts() throws {
        let content = OpenAIChatMessage.contentValue(text: "compare", imagesBase64: ["QQ==", "Qg=="])
        let parts = try XCTUnwrap(content as? [[String: Any]])
        XCTAssertEqual(parts.count, 3, "text part + one image_url part per image")
        XCTAssertEqual(parts.filter { $0["type"] as? String == "image_url" }.count, 2)
    }

    func testQuickModeCapsMaxTokens() async throws {
        queueChatStream("data: [DONE]")
        _ = try await collectEvents(makeRequest(quickMode: true))
        let body = try XCTUnwrap(OllamaURLProtocolStub.recordedBodies.first)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["max_tokens"] as? Int, 256)
    }

    // MARK: - API key injection

    func testAPIKeyInjectedAsBearerWhenResolved() async throws {
        queueChatStream("data: [DONE]")
        let engine = makeEngine(resolveAPIKey: { _ in "sk-local" })
        for try await _ in engine.stream(request: makeRequest()) {}
        XCTAssertEqual(OllamaURLProtocolStub.recordedAuthorizationHeaders, ["Bearer sk-local"])
    }

    func testAPIKeyOmittedWhenKeyless() async throws {
        queueChatStream("data: [DONE]")
        _ = try await collectEvents(makeRequest())
        XCTAssertEqual(OllamaURLProtocolStub.recordedAuthorizationHeaders, [nil])
    }

    // MARK: - Health

    func testHealthReadyWhenModelListedOnServer() async {
        OllamaURLProtocolStub.responsesByPath["/v1/models"] = [
            .init(
                statusCode: 200,
                body: Data(#"{"data":[{"id":"qwen2-vl-7b-instruct"},{"id":"llama-3.2-3b"}]}"#.utf8),
                headers: [:]
            )
        ]
        let health = await makeEngine().health(
            baseURL: baseURL, model: "qwen2-vl-7b-instruct", acceptInsecureRemote: false
        )
        XCTAssertEqual(health, .ready)
    }

    func testHealthUnavailableWhenModelNotServed() async {
        OllamaURLProtocolStub.responsesByPath["/v1/models"] = [
            .init(statusCode: 200, body: Data(#"{"data":[{"id":"llama-3.2-3b"}]}"#.utf8), headers: [:])
        ]
        let health = await makeEngine().health(
            baseURL: baseURL, model: "qwen2-vl-7b-instruct", acceptInsecureRemote: false
        )
        guard case .unavailable(let message) = health else {
            return XCTFail("Expected unavailable, got \(health)")
        }
        XCTAssertTrue(message.contains("qwen2-vl-7b-instruct"))
    }

    func testHealthUnavailableWhenNoModelChosen() async {
        OllamaURLProtocolStub.responsesByPath["/v1/models"] = [
            .init(statusCode: 200, body: Data(#"{"data":[{"id":"llama-3.2-3b"}]}"#.utf8), headers: [:])
        ]
        let health = await makeEngine().health(baseURL: baseURL, model: "  ", acceptInsecureRemote: false)
        guard case .unavailable = health else {
            return XCTFail("Expected unavailable for an empty model tag, got \(health)")
        }
    }

    // MARK: - Capability probes stay honestly unknown

    func testCapabilitiesAndContextLengthReturnNilAlways() async {
        let engine = makeEngine()
        let capabilities = await engine.capabilities(
            model: "anything", baseURL: baseURL, acceptInsecureRemote: false
        )
        let contextLength = await engine.contextLength(
            model: "anything", baseURL: baseURL, acceptInsecureRemote: false
        )
        XCTAssertNil(capabilities, "No capability metadata exists — nil keeps the vision gate at .unknown.")
        XCTAssertNil(contextLength)
        let supportsVision = await engine.supportsVision(
            model: "anything", baseURL: baseURL, acceptInsecureRemote: false
        )
        XCTAssertNil(supportsVision)
    }

    // MARK: - Follow-ups

    func testFollowUpsUseJSONSchemaAndParseSuggestions() async throws {
        let body = #"{"choices":[{"message":{"content":"{\"suggestions\":[\"How do I fix this?\",\"What changed?\"]}"}}],"usage":{"prompt_tokens":10,"completion_tokens":12}}"#
        OllamaURLProtocolStub.responsesByPath["/v1/chat/completions"] = [
            .init(statusCode: 200, body: Data(body.utf8), headers: [:])
        ]
        let result = await makeEngine().generateFollowUps(request: makeRequest())
        XCTAssertEqual(result.suggestions, ["How do I fix this?", "What changed?"])
        XCTAssertEqual(result.stats?.promptTokens, 10)
        let sent = try XCTUnwrap(OllamaURLProtocolStub.recordedBodies.first)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let format = try XCTUnwrap(root["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
    }

    func testFollowUpsFallBackToJSONObjectModeWhenSchemaRejected() async throws {
        let success = #"{"choices":[{"message":{"content":"{\"suggestions\":[\"Next step?\"]}"}}]}"#
        OllamaURLProtocolStub.responsesByPath["/v1/chat/completions"] = [
            .init(statusCode: 400, body: Data(#"{"error":{"message":"response_format json_schema unsupported"}}"#.utf8), headers: [:]),
            .init(statusCode: 200, body: Data(success.utf8), headers: [:]),
        ]
        let result = await makeEngine().generateFollowUps(request: makeRequest())
        XCTAssertEqual(result.suggestions, ["Next step?"])
        let retry = try XCTUnwrap(OllamaURLProtocolStub.recordedBodies.last)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: retry) as? [String: Any])
        let format = try XCTUnwrap(root["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_object")
    }

    func testFollowUpsBestEffortSwallowServerError() async {
        OllamaURLProtocolStub.responsesByPath["/v1/chat/completions"] = [
            .init(statusCode: 500, body: Data(#"{"error":"down"}"#.utf8), headers: [:])
        ]
        let result = await makeEngine().generateFollowUps(request: makeRequest())
        XCTAssertEqual(result.suggestions, [])
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PeeknookCore

final class OllamaURLProtocolStub: URLProtocol {
    struct QueuedResponse {
        let statusCode: Int
        let body: Data
        let headers: [String: String]
    }

    static var responsesByPath: [String: [QueuedResponse]] = [:]
    static var recordedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? "/"
        if request.httpMethod == "POST", let body = Self.requestBody(from: request) {
            Self.recordedBodies.append(body)
        }
        guard var queue = Self.responsesByPath[path], !queue.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = queue.removeFirst()
        Self.responsesByPath[path] = queue.isEmpty ? nil : queue
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

private func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OllamaURLProtocolStub.self]
    return URLSession(configuration: config)
}

@MainActor
final class OllamaInferenceEngineHTTPTests: XCTestCase {
    override func setUp() {
        OllamaURLProtocolStub.responsesByPath = [:]
        OllamaURLProtocolStub.recordedBodies = []
    }

    func testStreamYieldsTokensOnSuccess() async throws {
        let streamBody = """
        {"message":{"content":"hi"},"done":false}
        {"message":{"content":"!"},"done":true,"prompt_eval_count":10,"eval_count":2,"eval_duration":100000000}
        """.data(using: .utf8)!
        OllamaURLProtocolStub.responsesByPath = [
            "/api/version": [.init(statusCode: 200, body: Data(), headers: [:])],
            "/api/tags": [.init(
                statusCode: 200,
                body: #"{"models":[{"name":"gemma4:e4b"}]}"#.data(using: .utf8)!,
                headers: [:]
            )],
            "/api/chat": [.init(statusCode: 200, body: streamBody, headers: [:])]
        ]

        let engine = OllamaInferenceEngine(session: makeStubSession())
        let request = InferenceRequest(
            mode: .general,
            messages: [.init(role: .user, text: "explain", imageBase64: nil)],
            model: "gemma4:e4b",
            ollamaBaseURL: "http://stub.test:11434"
        )

        var tokens: [String] = []
        var stats: InferenceStats?
        for try await event in engine.stream(request: request) {
            switch event {
            case .token(let piece): tokens.append(piece)
            case .completed(let s): stats = s
            }
        }
        XCTAssertEqual(tokens.joined(), "hi!")
        XCTAssertEqual(stats?.promptTokens, 10)
        XCTAssertEqual(stats?.responseTokens, 2)
    }

    func testStreamRetriesWithoutThinkOn400() async throws {
        let thinkError = #"{"error":"unknown field think"}"#.data(using: .utf8)!
        let streamBody = """
        {"message":{"content":"ok"},"done":true}
        """.data(using: .utf8)!
        OllamaURLProtocolStub.responsesByPath = [
            "/api/version": [.init(statusCode: 200, body: Data(), headers: [:])],
            "/api/tags": [.init(
                statusCode: 200,
                body: #"{"models":[{"name":"gemma4:e4b"}]}"#.data(using: .utf8)!,
                headers: [:]
            )],
            "/api/chat": [
                .init(statusCode: 400, body: thinkError, headers: [:]),
                .init(statusCode: 200, body: streamBody, headers: [:])
            ]
        ]

        let engine = OllamaInferenceEngine(session: makeStubSession())
        let request = InferenceRequest(
            mode: .general,
            messages: [.init(role: .user, text: "x", imageBase64: nil)],
            model: "gemma4:e4b",
            ollamaBaseURL: "http://stub.test:11434"
        )

        var answer = ""
        for try await event in engine.stream(request: request) {
            if case .token(let piece) = event { answer += piece }
        }
        XCTAssertEqual(answer, "ok")
        XCTAssertEqual(OllamaURLProtocolStub.recordedBodies.count, 2)
        let first = String(data: OllamaURLProtocolStub.recordedBodies[0], encoding: .utf8) ?? ""
        XCTAssertTrue(first.contains("\"think\":false"))
    }

    func testUsesRemoteOllamaHostParsing() {
        XCTAssertFalse(PeeknookSettings(ollamaBaseURL: "http://127.0.0.1:11434").usesRemoteOllama)
        XCTAssertFalse(PeeknookSettings(ollamaBaseURL: "http://localhost:11434").usesRemoteOllama)
        XCTAssertTrue(PeeknookSettings(ollamaBaseURL: "http://192.168.1.10:11434").usesRemoteOllama)
        XCTAssertTrue(PeeknookSettings(ollamaBaseURL: "http://ollama.home:11434").usesRemoteOllama)
    }
}

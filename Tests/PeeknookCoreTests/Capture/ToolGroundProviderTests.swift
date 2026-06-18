// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Slice 2 of the tool-ground platform: the `ToolGroundProvider` runs a profile's `ToolSpec` over a
/// fresh capture, POSTs it through the HTTPS gate, and folds the verified response as a `.tool` text
/// leg. These cover the provider in isolation (HTTP stubbed) plus the registry narrowing, the readiness
/// composition, and one end-to-end pass through the capture coordinator.
final class ToolGroundProviderTests: XCTestCase {
    private let encoding = CaptureEncodingPolicy.resolve(scope: .window, quick: false, quality: .balanced)
    private let skKey = "sk-test-abcdefghijklmnopqrstuvwxyz1234567890"
    private let token = SensitiveContentPolicy.redactionToken

    private func screenStub(text: String = "selected text") -> StubCaptureProvider {
        StubCaptureProvider(sampleText: text, screenshotBase64: StubCaptureProvider.defaultScreenshotBase64)
    }

    // MARK: - The happy path: a verified text leg

    func testRunsToolAndFoldsResultAsPrimaryTextLeg() async throws {
        let client = RecordingToolHTTPClient(response: "FEN: 8/8 ...; best: e4 (+0.3)")
        let provider = ToolGroundProvider(screenProvider: screenStub(), http: client)
        let spec = ToolSpec(
            transport: .http, url: "http://127.0.0.1:7000",
            sendsScreenshot: true, sendsText: false, outputLabel: "Chess engine analysis"
        )

        let result = try await provider.runTool(spec, scope: .window, quick: false, encoding: encoding)

        XCTAssertEqual(result.ground, .tool)
        XCTAssertEqual(result.text, "FEN: 8/8 ...; best: e4 (+0.3)")
        XCTAssertEqual(result.sourceLabel, "Chess engine analysis")
        XCTAssertFalse(result.hasVision, "a tool leg is primary text, never an image")
        XCTAssertNotNil(client.lastRequest?.screenshotBase64, "the frame rides to the tool when sendsScreenshot")
        XCTAssertNil(client.lastRequest?.text, "no text is sent when sendsText is false")
        XCTAssertEqual(client.lastTimeout, spec.timeoutSeconds, "the spec timeout is handed to the client")
    }

    func testScreenshotOmittedWhenSendsScreenshotFalse() async throws {
        let client = RecordingToolHTTPClient(response: "result")
        let provider = ToolGroundProvider(screenProvider: screenStub(), http: client)
        let spec = ToolSpec(transport: .http, url: "http://127.0.0.1:7000", sendsScreenshot: false, sendsText: true)
        _ = try await provider.runTool(spec, scope: .window, quick: false, encoding: encoding)
        XCTAssertNil(client.lastRequest?.screenshotBase64, "no screenshot is sent when sendsScreenshot is false")
        XCTAssertEqual(client.lastRequest?.text, "selected text", "the extracted text is sent when sendsText")
    }

    // MARK: - Redaction parity with inference (remote tool only)

    func testRemoteToolRedactsSentTextButLoopbackSendsVerbatim() async throws {
        let remoteClient = RecordingToolHTTPClient(response: "ok")
        let remote = ToolGroundProvider(screenProvider: screenStub(text: "key \(skKey) here"), http: remoteClient)
        _ = try await remote.runTool(
            ToolSpec(transport: .http, url: "https://remote.example.com:7000", sendsScreenshot: false, sendsText: true),
            scope: .window, quick: false, encoding: encoding
        )
        let remoteText = remoteClient.lastRequest?.text ?? ""
        XCTAssertFalse(remoteText.contains(skKey), "a remote tool gets the secret stripped from the sent text")
        XCTAssertTrue(remoteText.contains(token))

        let localClient = RecordingToolHTTPClient(response: "ok")
        let local = ToolGroundProvider(screenProvider: screenStub(text: "key \(skKey) here"), http: localClient)
        _ = try await local.runTool(
            ToolSpec(transport: .http, url: "http://127.0.0.1:7000", sendsScreenshot: false, sendsText: true),
            scope: .window, quick: false, encoding: encoding
        )
        XCTAssertEqual(localClient.lastRequest?.text, "key \(skKey) here", "a loopback tool gets the text verbatim")
    }

    // MARK: - The HTTPS gate and unusable specs

    func testRemoteHTTPToolRejectedByTheGate() async {
        let client = RecordingToolHTTPClient(response: "x")
        let provider = ToolGroundProvider(screenProvider: screenStub(), http: client)
        await assertCaptureFailed(
            try await provider.runTool(
                ToolSpec(transport: .http, url: "http://remote.example.com:7000"),
                scope: .window, quick: false, encoding: encoding
            ),
            "a non-loopback http tool must be rejected unless it uses HTTPS"
        )
        XCTAssertNil(client.lastRequest, "the gate rejects before any request is made")
    }

    func testUnusableSpecThrowsBeforeAnyRequest() async {
        let client = RecordingToolHTTPClient(response: "x")
        let provider = ToolGroundProvider(screenProvider: screenStub(), http: client)
        await assertCaptureFailed(
            try await provider.runTool(ToolSpec(transport: .http, url: nil), scope: .window, quick: false, encoding: encoding),
            "a spec with no endpoint is unusable"
        )
        XCTAssertNil(client.lastRequest)
    }

    func testCommandTransportRejectedInSlice2() async {
        let provider = ToolGroundProvider(screenProvider: screenStub(), http: RecordingToolHTTPClient(response: "x"))
        await assertCaptureFailed(
            try await provider.runTool(ToolSpec(transport: .command, command: "/opt/x"), scope: .window, quick: false, encoding: encoding),
            "slice 2 ships the HTTP transport only"
        )
    }

    // MARK: - Degrade-not-block on tool failure

    func testEmptyToolResultThrowsNoContent() async {
        let provider = ToolGroundProvider(screenProvider: screenStub(), http: RecordingToolHTTPClient(response: "   "))
        do {
            _ = try await provider.runTool(ToolSpec(transport: .http, url: "http://127.0.0.1:7000"), scope: .window, quick: false, encoding: encoding)
            XCTFail("an empty tool result must throw, not ship a blank leg")
        } catch {
            XCTAssertEqual(error as? CaptureError, .noContent)
        }
    }

    func testToolClientErrorPropagatesAsCaptureFailure() async {
        let provider = ToolGroundProvider(
            screenProvider: screenStub(),
            http: RecordingToolHTTPClient(error: CaptureError.failed("status 500"))
        )
        await assertCaptureFailed(
            try await provider.runTool(ToolSpec(transport: .http, url: "http://127.0.0.1:7000"), scope: .window, quick: false, encoding: encoding),
            "a transport/status failure surfaces as a recoverable capture failure"
        )
    }

    // MARK: - Registry narrowing + readiness composition

    func testRegistryNarrowsToolProvider() {
        let registry = GroundRegistry([
            .screen: screenStub(),
            .tool: ToolGroundProvider(screenProvider: screenStub(), http: StubToolHTTPClient()),
        ])
        XCTAssertNotNil(registry.toolProvider(for: .tool))
        XCTAssertNil(registry.toolProvider(for: .screen), "the screen provider is not a tool runner")
    }

    func testToolProfileRequiresScreenRecordingOnlyWhenSendingScreenshot() {
        let sending = GroundProfile(
            id: "t1", displayNameKey: "x", symbol: "x", primaryGround: .tool, activeGrounds: [.tool],
            isBuiltIn: false, toolSpec: ToolSpec(transport: .http, url: "http://127.0.0.1:1", sendsScreenshot: true)
        )
        XCTAssertTrue(sending.requiredPermissions.contains(.screenRecording), "a screenshot-sending tool needs Screen Recording")

        let notSending = GroundProfile(
            id: "t2", displayNameKey: "x", symbol: "x", primaryGround: .tool, activeGrounds: [.tool],
            isBuiltIn: false, toolSpec: ToolSpec(transport: .http, url: "http://127.0.0.1:1", sendsScreenshot: false)
        )
        XCTAssertFalse(notSending.requiredPermissions.contains(.screenRecording), "a text-only tool needs no TCC")
    }

    // MARK: - End to end through the capture coordinator

    @MainActor
    func testToolProfileCaptureFoldsToolResultAsToolLeg() async throws {
        let screen = StubCaptureProvider(sampleText: "board", screenshotBase64: StubCaptureProvider.defaultScreenshotBase64)
        let toolClient = RecordingToolHTTPClient(response: "FEN: r1bqkbnr ...; best: e4")
        let tool = ToolGroundProvider(screenProvider: screen, http: toolClient)
        let engine = RecordingAnswerEngine(answer: "play e4 to take the center")
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "m"),
            captureRegistry: GroundRegistry([.screen: screen, .tool: tool]),
            inference: engine
        )
        let store = ProfileStore(defaults: UserDefaults(suiteName: "tooltests-\(UUID().uuidString)")!)
        orchestrator.profileStore = store
        let toolProfile = GroundProfile(
            id: "t1", displayNameKey: "Chess", symbol: "checkerboard.rectangle",
            primaryGround: .tool, activeGrounds: [.tool], isBuiltIn: false, displayName: "Chess",
            instruction: "Explain the engine's best move; never invent one.",
            toolSpec: ToolSpec(transport: .http, url: "http://127.0.0.1:7000", outputLabel: "Chess engine analysis")
        )
        let added = store.importPreset(from: try ProfilePreset.export([toolProfile]))
        orchestrator.settings.activeProfileID = try XCTUnwrap(added.first).id

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("play e4 to take the center")

        guard case .image(let capture)? = orchestrator.conversation.first(where: \.isImage)?.kind else {
            return XCTFail("expected a tool capture turn; phase = \(orchestrator.phase)")
        }
        XCTAssertEqual(capture.ground, .tool, "the committed leg is the tool ground")
        XCTAssertEqual(capture.text, "FEN: r1bqkbnr ...; best: e4", "the tool's verified output became the leg's text")
        XCTAssertFalse(capture.hasVision, "the tool leg carries no image")
        XCTAssertNotNil(toolClient.lastRequest?.screenshotBase64, "the screen frame was sent to the tool")

        let sent = engine.lastMessages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(sent.contains("FEN: r1bqkbnr ...; best: e4"), "the tool result rode into the prompt as grounding")
    }

    // MARK: - Helper

    private func assertCaptureFailed(
        _ expression: @autoclosure () async throws -> CaptureResult,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail(message, file: file, line: line)
        } catch let error as CaptureError {
            if case .failed = error { return }
            XCTFail("expected CaptureError.failed, got \(error): \(message)", file: file, line: line)
        } catch {
            XCTFail("expected CaptureError.failed, got \(error): \(message)", file: file, line: line)
        }
    }
}

/// Records the tool request so a test can assert exactly what was POSTed, and can inject a canned
/// response or a thrown error.
private final class RecordingToolHTTPClient: ToolHTTPClient, @unchecked Sendable {
    private(set) var lastRequest: ToolRequest?
    private(set) var lastURL: URL?
    private(set) var lastTimeout: Double?
    private let response: String
    private let error: Error?

    init(response: String = "ok", error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func runTool(_ request: ToolRequest, url: URL, timeoutSeconds: Double) async throws -> String {
        lastRequest = request
        lastURL = url
        lastTimeout = timeoutSeconds
        if let error { throw error }
        return response
    }
}

/// Minimal recording inference engine: streams a fixed answer and captures the request messages so a
/// test can assert the tool leg reached the prompt. `capabilities == nil` keeps the vision gate at
/// `.unknown` (never blocks); a tool leg carries no image, so the gate is skipped anyway.
private final class RecordingAnswerEngine: InferenceEngine, @unchecked Sendable {
    private(set) var lastMessages: [InferenceMessage] = []
    private let answer: String

    init(answer: String) { self.answer = answer }

    func health(baseURL: String, model: String, acceptInsecureRemote: Bool) async -> InferenceHealth { .ready }
    func warmUp(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Bool { true }
    func contextLength(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> Int? { nil }
    func capabilities(model: String, baseURL: String, acceptInsecureRemote: Bool) async -> [String]? { nil }

    func generateFollowUps(request: InferenceRequest) async -> FollowUpGenerationResult {
        FollowUpGenerationResult(suggestions: [], stats: nil)
    }

    func stream(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        lastMessages = request.messages
        let answer = self.answer
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(answer))
            continuation.yield(.completed(nil))
            continuation.finish()
        }
    }
}

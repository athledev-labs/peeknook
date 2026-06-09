// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class CaptureResultGroundTests: XCTestCase {
    private let sampleBase64 = StubCaptureProvider.defaultScreenshotBase64

    func testGroundDefaultsToScreen() {
        XCTAssertEqual(CaptureResult(text: nil, sourceLabel: "Window").ground, .screen)
    }

    func testCameraGroundRoundTripsThroughJSON() throws {
        let capture = CaptureResult(
            text: nil,
            sourceLabel: "Camera (live)",
            screenshotBase64: sampleBase64,
            ground: .camera
        )
        let decoded = try JSONDecoder().decode(CaptureResult.self, from: JSONEncoder().encode(capture))
        XCTAssertEqual(decoded.ground, .camera)
    }

    func testLegacyJSONWithoutGroundDecodesAsScreen() throws {
        let legacy = Data(#"{"sourceLabel":"Window"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CaptureResult.self, from: legacy).ground, .screen)
    }

    func testUnknownGroundRawValueDegradesToScreen() throws {
        // Archives outlive app versions: a ground from a newer build must degrade to `.screen`,
        // never throw — archive threads decode as a whole, so a throw strands the entire thread.
        let future = Data(#"{"sourceLabel":"Window","ground":"hologram"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CaptureResult.self, from: future).ground, .screen)
    }

    func testBlobBackedEncodeDropsInlineBase64ButKeepsGround() throws {
        let capture = CaptureResult(
            text: nil,
            sourceLabel: "Camera (live)",
            screenshotBase64: sampleBase64,
            screenshotBlobID: UUID(),
            ground: .camera
        )
        let data = try JSONEncoder().encode(capture)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("screenshotBase64"), "Blob-backed captures must not inline base64")
        XCTAssertEqual(try JSONDecoder().decode(CaptureResult.self, from: data).ground, .camera)
    }

    func testTargetLabelDerivesFromGround() {
        let camera = CaptureResult(text: nil, sourceLabel: "Camera (live)", ground: .camera)
        XCTAssertEqual(camera.targetLabel, "Camera")
        let screen = CaptureResult(text: nil, sourceLabel: "Vision", appName: "Safari", windowTitle: "Docs")
        XCTAssertEqual(screen.targetLabel, "Safari · Docs")
    }

    func testCapturePreviewCopiesGround() {
        let capture = CaptureResult(text: nil, sourceLabel: "Camera (live)", ground: .camera)
        let preview = CapturePreview(capture: capture)
        XCTAssertEqual(preview.ground, .camera)
        XCTAssertEqual(preview.targetLabel, "Camera")
    }

    /// Blob externalization rebuilds the `CaptureResult` — the one place `ground` could silently
    /// revert to `.screen` on disk for every persisted camera turn.
    @MainActor
    func testStoredCaptureRetainsGroundThroughBlobExternalization() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-ground-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x", persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
        orchestrator.captureBlobStore = CaptureBlobStore(directory: dir)

        let stored = orchestrator.storedCapture(
            CaptureResult(text: nil, sourceLabel: "Camera (live)", screenshotBase64: sampleBase64, ground: .camera)
        )

        XCTAssertNotNil(stored.screenshotBlobID)
        XCTAssertEqual(stored.ground, .camera)
    }

    @MainActor
    func testArchiveRoundTripPreservesCameraGround() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-ground-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)

        let capture = CaptureResult(
            text: nil,
            sourceLabel: "Camera (live)",
            screenshotBase64: sampleBase64,
            ground: .camera
        )
        let thread = ConversationThread(
            turns: [
                ChatTurn(id: 1, kind: .image(capture)),
                ChatTurn(id: 2, kind: .assistant("answer")),
            ],
            turnCounter: 2
        )
        let saveResult = await store.save(thread)
        XCTAssertTrue(saveResult.isSuccess)

        let loaded = await store.load(id: thread.id)
        guard case .image(let roundTripped)? = loaded?.turns.first?.kind else {
            return XCTFail("Expected an image turn back from the archive")
        }
        XCTAssertEqual(roundTripped.ground, .camera)
    }
}

@MainActor
final class CameraSessionStubTests: XCTestCase {
    func testCaptureStillRequiresRunningPreview() async throws {
        let session = StubCameraSession()
        do {
            _ = try await session.captureStill()
            XCTFail("captureStill must throw before startPreview")
        } catch {}

        try await session.startPreview()
        let still = try await session.captureStill()
        XCTAssertEqual(still.ground, .camera)
        XCTAssertNotNil(still.screenshotBase64)
    }

    func testStopPreviewIsIdempotent() async throws {
        let session = StubCameraSession()
        try await session.startPreview()
        session.stopPreview()
        session.stopPreview()   // exit path + collapse teardown may both fire; must be safe
        XCTAssertEqual(session.stopPreviewCount, 2)
        XCTAssertFalse(session.isPreviewing)
    }

    func testRegistrySessionControllerExposesOnlyCameraFacet() {
        let camera = StubCameraSession()
        let registry = GroundRegistry([
            .screen: StubCaptureProvider(sampleText: "x"),
            .camera: camera,
        ])
        XCTAssertNil(registry.sessionController(for: .screen))
        XCTAssertTrue(registry.sessionController(for: .camera) === camera)
    }
}

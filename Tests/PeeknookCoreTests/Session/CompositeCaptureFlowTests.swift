// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Composite D12 slice 4: the screen + camera capture FSM. `beginComposite` grabs the screen leg,
/// opens the live camera, and the shutter commits BOTH legs atomically and runs one turn. Guards
/// the no-orphan / teardown / module-gate invariants and that a composite turn is vision-routed.
@MainActor
final class CompositeCaptureFlowTests: XCTestCase {
    private func makeOrchestrator(
        _ camera: StubCameraSession,
        engine: any InferenceEngine = MockInferenceEngine(tokens: ["a"]),
        compositeEnabled: Bool = true
    ) -> SessionOrchestrator {
        var settings = PeeknookSettings(textModel: "gemma4:e4b")
        settings.compositeCaptureEnabled = compositeEnabled
        return SessionOrchestrator(
            settings: settings,
            captureRegistry: GroundRegistry([
                .screen: StubCaptureProvider(sampleText: "screen"),
                .camera: camera,
            ]),
            inference: engine
        )
    }

    func testCompositeCommitsBothLegsScreenFirstAndAnswers() async {
        let camera = StubCameraSession()
        let o = makeOrchestrator(camera)

        o.beginComposite()
        let live = await o.waitUntil { o.phase == .cameraLive && camera.isPreviewing }
        XCTAssertTrue(live, "the screen leg is captured, then the live camera opens")

        o.shutter()
        let phase = await o.waitForResult("a")
        guard case .result = phase else { return XCTFail("expected result, got \(phase)") }

        // Two image legs sharing one group id, screen first (lower id) then camera, then the answer.
        let images = o.conversation.filter(\.isImage)
        XCTAssertEqual(images.count, 2)
        let groups = Set(images.compactMap(\.compositeGroupID))
        XCTAssertEqual(groups.count, 1, "both legs share exactly one composite group id")
        guard case .image(let screen)? = images.first?.kind,
              case .image(let cam)? = images.last?.kind else { return XCTFail("missing legs") }
        XCTAssertEqual(screen.ground, .screen, "lower-id leg is the screenshot")
        XCTAssertEqual(cam.ground, .camera, "higher-id leg is the camera photo")
        XCTAssertEqual(o.conversation.last?.kind, .assistant("a"))
    }

    func testCompositeShutterTearsDownCameraExactlyOnce() async {
        let camera = StubCameraSession()
        let o = makeOrchestrator(camera)
        o.beginComposite()
        _ = await o.waitUntil { o.phase == .cameraLive && camera.isPreviewing }

        o.shutter()
        _ = await o.waitForResult("a")
        XCTAssertEqual(camera.stopPreviewCount, 1, "the camera is torn down once, before the commit")
        XCTAssertNil(o.activeCameraSession)
    }

    func testCompositeDisabledIsNoOp() async {
        let camera = StubCameraSession()
        let o = makeOrchestrator(camera, compositeEnabled: false)
        o.beginComposite()
        // No opt-in → the gate refuses; nothing captures, the camera never opens.
        let opened = await o.waitUntil { o.phase == .cameraLive }
        XCTAssertFalse(opened)
        XCTAssertEqual(o.phase, .idle)
        XCTAssertTrue(o.conversation.isEmpty)
        XCTAssertEqual(camera.startPreviewCount, 0)
    }

    func testCancelDuringCompositeLeavesNoOrphanAndTearsDown() async {
        let camera = StubCameraSession()
        let o = makeOrchestrator(camera)
        o.beginComposite()
        _ = await o.waitUntil { o.phase == .cameraLive && camera.isPreviewing }

        // Escape before the shutter: the screen leg was captured but never committed.
        o.cancelCameraLive()

        XCTAssertEqual(o.phase, .idle)
        XCTAssertEqual(camera.stopPreviewCount, 1, "the camera light goes out on cancel")
        XCTAssertNil(o.activeCameraSession)
        XCTAssertTrue(o.conversation.isEmpty, "an aborted composite leaves NO partial turn behind")
    }

    func testCompositeTurnIsVisionRoutedAndCarriesBothImages() async {
        let camera = StubCameraSession()
        let engine = ScriptedEngine(responsesPerCall: [["a"]])
        let o = makeOrchestrator(camera, engine: engine)
        o.settings.fastTextFollowUps = true   // even with fast follow-ups on, a capture turn stays vision
        o.settings.textOnlyModelTag = "tiny-text"

        o.beginComposite()
        _ = await o.waitUntil { o.phase == .cameraLive && camera.isPreviewing }
        o.shutter()
        _ = await o.waitForResult("a")

        let request = engine.requests.last
        XCTAssertEqual(request?.model, "gemma4:e4b", "a composite (capture != nil) routes to the vision model")
        let composite = request?.messages.first { $0.imagesBase64.count == 2 }
        XCTAssertNotNil(composite, "both legs fold into one user message with two images")
    }
}

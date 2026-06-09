// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class GroundRegistryTests: XCTestCase {
    func testResolveReturnsRegisteredProvider() throws {
        let registry = GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")])
        XCTAssertTrue(try registry.resolve(.screen) is StubCaptureProvider)
    }

    func testResolveThrowsNamingTheUnregisteredGround() {
        let registry = GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")])
        XCTAssertThrowsError(try registry.resolve(.camera)) { error in
            guard case .failed(let message) = error as? CaptureError else {
                return XCTFail("Expected CaptureError.failed, got \(error)")
            }
            XCTAssertTrue(message.contains("camera"), "Error should name the missing ground: \(message)")
        }
    }

    func testProviderForReturnsNilWhenAbsent() {
        let registry = GroundRegistry([:])
        XCTAssertNil(registry.provider(for: .screen))
    }

    /// A profile whose primary ground has no provider must surface a loud, recoverable failure —
    /// never a silent fallback to another ground.
    @MainActor
    func testCaptureFailsLoudlyWhenPrimaryGroundHasNoProvider() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "x"),
            captureRegistry: GroundRegistry([:]),
            inference: MockInferenceEngine(tokens: ["unused"])
        )

        orchestrator.beginCapture()

        let phase = await orchestrator.waitForFailed()
        guard case .failed = phase else {
            return XCTFail("Expected failed phase, got \(phase)")
        }
    }
}

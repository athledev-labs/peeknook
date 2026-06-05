// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class PeekSettingsControllerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.settingsController")!
        defaults.removePersistentDomain(forName: "peeknook.tests.settingsController")
    }

    @MainActor
    func testUpdateSyncsOrchestratorSetupAndUserDefaults() {
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults)
        let controller = stack.settings

        controller.setCaptureScope(.display)
        controller.setQuickMode(true)
        controller.setOllamaBaseURL("http://192.168.1.10:11434")

        XCTAssertEqual(stack.orchestrator.settings.captureScope, .display)
        XCTAssertEqual(stack.setup.settings.captureScope, .display)
        XCTAssertTrue(stack.orchestrator.settings.quickMode)
        XCTAssertEqual(stack.setup.settings.ollamaBaseURL, "http://192.168.1.10:11434")

        let reloaded = PeeknookSettings.load(from: defaults)
        XCTAssertEqual(reloaded.captureScope, .display)
        XCTAssertTrue(reloaded.quickMode)
        XCTAssertEqual(reloaded.ollamaBaseURL, "http://192.168.1.10:11434")
    }

    @MainActor
    func testSetModeSyncsInMemoryCopies() {
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults)
        stack.settings.setMode(.explain)

        XCTAssertEqual(stack.orchestrator.settings.mode, .explain)
        XCTAssertEqual(stack.setup.settings.mode, .explain)
    }

    @MainActor
    func testPickModelReturnsNeedsDownloadWhenMissing() {
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults)

        let option = TextModelCatalog.offered[0]
        let result = stack.settings.pickModel(option)

        XCTAssertEqual(result, .needsDownload(option))
        XCTAssertNotEqual(stack.orchestrator.settings.textModel, option.tag)
    }

    @MainActor
    func testBeginModelDownloadSetsTextModelAndStartsPull() {
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults)
        let option = TextModelCatalog.offered[1]

        stack.settings.beginModelDownload(option)

        XCTAssertEqual(stack.orchestrator.settings.textModel, option.tag)
        XCTAssertEqual(stack.setup.settings.textModel, option.tag)
        XCTAssertEqual(PeeknookSettings.load(from: defaults).textModel, option.tag)
        XCTAssertTrue(stack.setup.isPullingModel)
    }

    @MainActor
    func testInferenceHealthUsesInjectedEngine() async {
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults)
        let health = await stack.settings.inferenceHealth()
        // Default stack uses OllamaInferenceEngine; without a live server this is unavailable,
        // but the call must complete without crashing.
        switch health {
        case .ready, .unavailable:
            break
        }
    }
}

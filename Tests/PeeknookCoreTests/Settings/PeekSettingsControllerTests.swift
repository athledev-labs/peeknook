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
        XCTAssertFalse(controller.setOllamaBaseURL("http://192.168.1.10:11434"))
        controller.setAcceptInsecureRemoteOllama(true)
        XCTAssertTrue(controller.setOllamaBaseURL("http://192.168.1.10:11434"))

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
        let initialModel = stack.orchestrator.settings.textModel

        let option = InferenceModelOption(custom: CustomModelEntry(tag: "peeknook-ci-missing:0"))
        let result = stack.settings.pickModel(option)

        XCTAssertEqual(result, .needsDownload(option))
        XCTAssertEqual(stack.orchestrator.settings.textModel, initialModel)
    }

    @MainActor
    func testSetActiveProfilePersistsAndDeleteActiveResetsToScreenDefault() throws {
        let stack = PeeknookServices.makeStack(
            settings: .default, defaults: defaults, dependencies: .testing()
        )
        let copy = try XCTUnwrap(stack.profileStore.duplicate(.screenDefault, name: "Mine"))

        stack.settings.setActiveProfile(id: copy.id)
        XCTAssertEqual(stack.orchestrator.settings.activeProfileID, copy.id)
        XCTAssertEqual(PeeknookSettings.load(from: defaults).activeProfileID, copy.id)
        XCTAssertEqual(stack.orchestrator.resolvedActiveProfile, copy)

        stack.settings.deleteProfile(id: copy.id)
        XCTAssertEqual(
            stack.orchestrator.settings.activeProfileID, GroundProfile.screenDefault.id,
            "Deleting the active profile resets the persisted id explicitly."
        )
        XCTAssertEqual(stack.orchestrator.resolvedActiveProfile, .screenDefault)
    }

    @MainActor
    func testDeleteNonActiveProfileLeavesActiveUnchanged() throws {
        let stack = PeeknookServices.makeStack(
            settings: .default, defaults: defaults, dependencies: .testing()
        )
        let copy = try XCTUnwrap(stack.profileStore.duplicate(.screenDefault, name: "Mine"))

        stack.settings.deleteProfile(id: copy.id)
        XCTAssertEqual(stack.orchestrator.settings.activeProfileID, GroundProfile.screenDefault.id)
        XCTAssertTrue(stack.profileStore.catalog.profiles.isEmpty)
    }

    @MainActor
    func testSetAnswerBackendSyncsAndPersists() {
        let stack = PeeknookServices.makeStack(
            settings: .default, defaults: defaults, dependencies: .testing()
        )
        let initialTextModel = stack.orchestrator.settings.textModel

        stack.settings.setAnswerBackend(.openAICompatible)

        XCTAssertEqual(stack.orchestrator.settings.answerBackend, .openAICompatible)
        XCTAssertEqual(PeeknookSettings.load(from: defaults).answerBackend, .openAICompatible)
        XCTAssertEqual(
            stack.orchestrator.settings.textModel, initialTextModel,
            "Switching backend must not touch the Ollama tag."
        )
    }

    @MainActor
    func testSetCaptureQualitySyncsAndPersists() {
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults)

        stack.settings.setCaptureQuality(.high)
        XCTAssertEqual(stack.orchestrator.settings.captureQuality, .high)
        XCTAssertEqual(PeeknookSettings.load(from: defaults).captureQuality, .high)
    }

    @MainActor
    func testPickerModelsFollowsActiveBackend() {
        let stack = PeeknookServices.makeStack(
            settings: .default, defaults: defaults, dependencies: .testing()
        )
        XCTAssertEqual(
            stack.settings.pickerModels().map(\.tag),
            stack.settings.availableModels.map(\.tag)
        )

        stack.settings.setAnswerBackend(.openAICompatible)
        stack.settings.update { $0.openAICompatibleModelTag = "qwen2-vl-7b-instruct" }
        let served = ["qwen2-vl-7b-instruct", "llama3.2:latest"]
        XCTAssertEqual(
            stack.settings.pickerModels(servedOpenAIModels: served).map(\.tag),
            served
        )
        XCTAssertFalse(stack.settings.showsModelLibraryBrowse)
        XCTAssertTrue(stack.settings.isPickerOptionInstalled("any-server-model"))
    }

    @MainActor
    func testPickModelOnOpenAICompatibleSelectsWithoutDownload() {
        let stack = PeeknookServices.makeStack(
            settings: .default, defaults: defaults, dependencies: .testing()
        )
        let initialTextModel = stack.orchestrator.settings.textModel
        stack.settings.setAnswerBackend(.openAICompatible)

        let option = InferenceModelOption(custom: CustomModelEntry(tag: "qwen2-vl-7b-instruct"))
        let result = stack.settings.pickModel(option)

        XCTAssertEqual(result, .selected, "No download path exists on a server-managed backend.")
        XCTAssertEqual(stack.orchestrator.settings.openAICompatibleModelTag, "qwen2-vl-7b-instruct")
        XCTAssertEqual(
            stack.orchestrator.settings.textModel, initialTextModel,
            "An OpenAI-compatible pick writes the overlay tag, never textModel."
        )
    }

    @MainActor
    func testOpenAICompatibleBaseURLRoutesThroughEndpointPolicy() {
        let stack = PeeknookServices.makeStack(
            settings: .default, defaults: defaults, dependencies: .testing()
        )

        XCTAssertFalse(
            stack.settings.setOpenAICompatibleBaseURL("http://192.168.1.10:1234"),
            "Plain HTTP to a non-loopback host must be rejected without the insecure opt-in."
        )
        stack.settings.setAcceptInsecureRemoteOpenAICompatible(true)
        XCTAssertTrue(stack.settings.setOpenAICompatibleBaseURL("http://192.168.1.10:1234"))
        XCTAssertTrue(stack.settings.setOpenAICompatibleBaseURL("http://127.0.0.1:1234"))
    }

    /// Anchor: no key material in UserDefaults, ever — the settings blob must not contain the key
    /// after a key write, and the key must round-trip through the credential store alone.
    @MainActor
    func testSetOpenAICompatibleAPIKeyNeverWritesToUserDefaults() throws {
        let credentialStore = InMemoryCredentialStore()
        let stack = PeeknookServices.makeStack(
            settings: .default, defaults: defaults,
            dependencies: .testing(credentialStore: credentialStore)
        )

        XCTAssertFalse(stack.settings.openAICompatibleKeyIsSet)
        XCTAssertTrue(stack.settings.setOpenAICompatibleAPIKey("sk-super-secret-1234"))
        XCTAssertTrue(stack.settings.openAICompatibleKeyIsSet)
        stack.settings.persist()

        let blob = try XCTUnwrap(defaults.data(forKey: PeeknookSettings.defaultsKey))
        let raw = try XCTUnwrap(String(data: blob, encoding: .utf8))
        XCTAssertFalse(raw.contains("sk-super-secret-1234"), "Key material reached peeknook.settings.v1.")
        XCTAssertEqual(
            credentialStore.apiKey(for: .openAICompatiblePrimary), "sk-super-secret-1234"
        )

        XCTAssertTrue(stack.settings.setOpenAICompatibleAPIKey(""))
        XCTAssertFalse(stack.settings.openAICompatibleKeyIsSet, "An empty key clears the slot.")
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
    func testAddCustomModelPersistsAndJoinsAvailableList() {
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults)

        let option = stack.settings.addCustomModel(tag: "qwen3-vl:8b")
        XCTAssertEqual(option?.tag, "qwen3-vl:8b")
        XCTAssertTrue(stack.settings.availableModels.contains { $0.tag == "qwen3-vl:8b" })
        XCTAssertEqual(PeeknookSettings.load(from: defaults).customModels.map(\.tag), ["qwen3-vl:8b"])
    }

    @MainActor
    func testAddCustomModelIsIdempotentAndIgnoresBlank() {
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults)

        _ = stack.settings.addCustomModel(tag: "llava:13b")
        _ = stack.settings.addCustomModel(tag: "llava:13b") // duplicate
        XCTAssertEqual(stack.settings.customModels.count, 1)

        XCTAssertNil(stack.settings.addCustomModel(tag: "   "))
        XCTAssertEqual(stack.settings.customModels.count, 1)
    }

    @MainActor
    func testRemoveCustomModelFallsBackWhenSelected() {
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults)

        _ = stack.settings.addCustomModel(tag: "mymodel:latest")
        stack.settings.selectInstalledModel("mymodel:latest")
        XCTAssertEqual(stack.orchestrator.settings.textModel, "mymodel:latest")

        stack.settings.removeCustomModel(tag: "mymodel:latest")
        XCTAssertTrue(stack.settings.customModels.isEmpty)
        XCTAssertEqual(
            stack.orchestrator.settings.textModel,
            SystemProfile.current().suggestedTextModel
        )
    }

    @MainActor
    func testInferenceHealthUsesInjectedEngine() async {
        let deps = PeeknookDependencies.testing(inference: MockInferenceEngine())
        let stack = PeeknookServices.makeStack(settings: .default, defaults: defaults, dependencies: deps)
        let health = await stack.settings.inferenceHealth()
        XCTAssertEqual(health, .ready)
    }
}

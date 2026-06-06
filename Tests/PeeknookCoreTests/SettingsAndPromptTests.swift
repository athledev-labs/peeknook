// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class SettingsAndPromptTests: XCTestCase {
    func testLegacySettingsDecodeKeepsValuesAndDefaultsQuickMode() throws {
        // A blob saved before `quickMode` existed must NOT reset the other fields.
        let legacy = Data("""
        {"mode":"general","previewBeforeInfer":false,"ollamaBaseURL":"http://host:1","textModel":"gemma4:e4b"}
        """.utf8)
        let settings = try JSONDecoder().decode(PeeknookSettings.self, from: legacy)
        XCTAssertEqual(settings.textModel, "gemma4:e4b")
        XCTAssertEqual(settings.ollamaBaseURL, "http://host:1")
        XCTAssertFalse(settings.previewBeforeInfer)
        XCTAssertFalse(settings.quickMode) // defaulted, not a decode failure
    }

    func testQuickModeRoundTrips() throws {
        let settings = PeeknookSettings(textModel: "gemma4:e4b", quickMode: true)
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: data)
        XCTAssertTrue(back.quickMode)
    }

    func testCaptureScopeDefaultsToWindowAndRoundTrips() throws {
        // Missing key (legacy blob) defaults to .window.
        let legacy = Data("""
        {"mode":"general","previewBeforeInfer":true,"ollamaBaseURL":"http://127.0.0.1:11434","textModel":"gemma4:e4b"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).captureScope, .window)

        let display = PeeknookSettings(textModel: "gemma4:e4b", captureScope: .display)
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(display))
        XCTAssertEqual(back.captureScope, .display)
    }

    func testQuickPromptAddsTerseInstruction() {
        let capture = CaptureResult(text: nil, sourceLabel: "Front window (vision)", screenshotBase64: "x")
        let normal = PromptBuilder.userMessage(capture: capture, mode: .general, quick: false)
        let quick = PromptBuilder.userMessage(capture: capture, mode: .general, quick: true)
        XCTAssertFalse(normal.contains("Quick mode"))
        XCTAssertTrue(quick.contains("Quick mode"))
    }

    func testCaptureHotkeyDefaultsToCommandShiftPAndRoundTrips() throws {
        let legacy = Data("""
        {"mode":"general","textModel":"gemma4:e4b"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).captureHotkey, .default)

        var custom = PeeknookSettings(textModel: "gemma4:e4b")
        custom.captureHotkey = CaptureHotkey(keyCode: 9, carbonModifiers: 256, keySymbol: "V")
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(back.captureHotkey.keySymbol, "V")
    }

    func testTextModelCatalogDisplayName() {
        XCTAssertEqual(TextModelCatalog.displayName(for: "gemma4:e2b"), "Gemma 4 E2B")
        XCTAssertEqual(TextModelCatalog.displayName(for: "gemma4:26b"), "Gemma 4 26B")
        XCTAssertEqual(TextModelCatalog.displayName(for: "custom:model"), "custom:model")
    }

    func testInferenceModelOptionMenuDetail() {
        let option = TextModelCatalog.offered[1]
        XCTAssertEqual(option.displayName, "Gemma 4 E4B")
        XCTAssertEqual(option.menuDetail, "gemma4:e4b · Ollama · ~10 GB")
    }

    func testSuggestFollowUpsSettingDefaultsTrueAndRoundTrips() throws {
        // Legacy blob without the key keeps suggestions on.
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b"}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).suggestFollowUps)

        let off = PeeknookSettings(textModel: "gemma4:e4b", suggestFollowUps: false)
        XCTAssertFalse(try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(off)).suggestFollowUps)
    }

    func testParseSuggestionsReadsSchemaConstrainedJSON() {
        // What Ollama returns for a non-stream chat with a JSON-schema `format`: blank dropped,
        // then capped at 3 (so the trailing "extra" is cut).
        let body = Data(#"""
        {"message":{"role":"assistant","content":"{\"suggestions\":[\"How do I fix it?\",\"  \",\"What line?\",\"Why did it happen?\",\"extra\"]}"}}
        """#.utf8)
        let suggestions = OllamaInferenceEngine.parseSuggestions(from: body)
        XCTAssertEqual(suggestions, ["How do I fix it?", "What line?", "Why did it happen?"])
    }

    func testParseSuggestionsToleratesGarbage() {
        XCTAssertTrue(OllamaInferenceEngine.parseSuggestions(from: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(OllamaInferenceEngine.parseSuggestions(from: Data(#"{"message":{"content":"oops"}}"#.utf8)).isEmpty)
    }

    func testParseChatStatsReadsTokenCounts() {
        let body = Data(#"{"done":true,"prompt_eval_count":1200,"eval_count":45,"eval_duration":500000000}"#.utf8)
        let stats = OllamaInferenceEngine.parseChatStats(from: body)
        XCTAssertEqual(stats?.promptTokens, 1200)
        XCTAssertEqual(stats?.responseTokens, 45)
    }

    func testParseContextLengthFindsArchPrefixedKey() {
        let body = Data(#"{"model_info":{"general.architecture":"gemma3","gemma3.context_length":8192}}"#.utf8)
        XCTAssertEqual(OllamaInferenceEngine.parseContextLength(from: body), 8192)
        XCTAssertNil(OllamaInferenceEngine.parseContextLength(from: Data("{}".utf8)))
    }

    func testParseCapabilitiesReadsArrayAndNilWhenAbsent() {
        let body = Data(#"{"capabilities":["completion","vision"]}"#.utf8)
        XCTAssertEqual(OllamaInferenceEngine.parseCapabilities(from: body), ["completion", "vision"])
        XCTAssertNil(OllamaInferenceEngine.parseCapabilities(from: Data("{}".utf8)))
    }

    func testCustomModelsDecodeTolerantlyAndRoundTrip() throws {
        // Legacy blob (no key) keeps an empty list, not a decode failure.
        let legacy = Data(#"{"mode":"general","textModel":"gemma4:e4b"}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(PeeknookSettings.self, from: legacy).customModels.isEmpty)

        let withCustom = PeeknookSettings(
            textModel: "gemma4:e4b",
            customModels: [CustomModelEntry(tag: "qwen3-vl:8b", displayName: "Qwen3 VL")]
        )
        let back = try JSONDecoder().decode(PeeknookSettings.self, from: JSONEncoder().encode(withCustom))
        XCTAssertEqual(back.customModels.map(\.tag), ["qwen3-vl:8b"])
        XCTAssertEqual(back.customModels.first?.resolvedDisplayName, "Qwen3 VL")
    }

    func testCustomModelEntryTrimsAndFallsBackToTag() {
        let entry = CustomModelEntry(tag: "  llava:13b  ", displayName: "   ")
        XCTAssertEqual(entry.tag, "llava:13b")
        XCTAssertNil(entry.displayName)
        XCTAssertEqual(entry.resolvedDisplayName, "llava:13b")
    }

    func testMergedCatalogAppendsCustomAndDedupes() {
        let custom = [
            CustomModelEntry(tag: "qwen3-vl:8b"),
            CustomModelEntry(tag: "gemma4:e2b"), // already curated — must not duplicate
        ]
        let merged = TextModelCatalog.merged(custom: custom)
        XCTAssertEqual(merged.filter { $0.tag == "gemma4:e2b" }.count, 1)
        XCTAssertTrue(merged.contains { $0.tag == "qwen3-vl:8b" })
        XCTAssertEqual(TextModelCatalog.displayName(for: "qwen3-vl:8b", custom: custom), "qwen3-vl:8b")
    }

    @MainActor
    func testOnboardingCompletePersists() {
        let defaults = UserDefaults(suiteName: "peeknook.tests.onboarding")!
        defaults.removePersistentDomain(forName: "peeknook.tests.onboarding")
        let setup = SetupCoordinator(settings: .default, defaults: defaults)
        XCTAssertFalse(setup.hasCompletedOnboarding)
        setup.markOnboardingComplete()
        XCTAssertTrue(defaults.bool(forKey: SetupCoordinator.onboardingCompleteKey))
        let reloaded = SetupCoordinator(settings: .default, defaults: defaults)
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
    }
}

// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure routing leaf: an English target takes the engine's single-pass translate route; any other
/// target transcribes for the separate LLM pass. The plan carries the source locale through untouched, and
/// `producesTargetLanguage` mirrors the mode so the coordinator and the engine never disagree.
final class CaptionEnginePolicyTests: XCTestCase {
    private let source = Locale(identifier: "ko-KR")

    private func directive(_ target: String) -> TranslationDirective {
        TranslationDirective(targetLanguage: target)
    }

    func testEnglishTargetRoutesToTranslateToEnglish() {
        for label in ["English", "english", "  EN  ", "en-US", "eng", "English (UK)"] {
            let plan = CaptionEnginePolicy.plan(target: directive(label), sourceLocale: source)
            XCTAssertEqual(plan.mode, .translateToEnglish, "\(label) should take the single-pass English route")
            XCTAssertTrue(plan.producesTargetLanguage)
        }
    }

    func testNonEnglishTargetRoutesToTranscribe() {
        for label in ["German", "Korean", "español", "français", "Englishman", "Pidgin English", ""] {
            let plan = CaptionEnginePolicy.plan(target: directive(label), sourceLocale: source)
            XCTAssertEqual(plan.mode, .transcribe, "\(label) should transcribe for the LLM pass")
            XCTAssertFalse(plan.producesTargetLanguage)
        }
    }

    func testPlanCarriesSourceLocaleThrough() {
        let plan = CaptionEnginePolicy.plan(target: directive("German"), sourceLocale: source)
        XCTAssertEqual(plan.sourceLocale, source)
    }

    func testTargetsBuiltInTranslationIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(CaptionEnginePolicy.targetsBuiltInTranslation(" English "))
        XCTAssertTrue(CaptionEnginePolicy.targetsBuiltInTranslation("EN"))
        XCTAssertFalse(CaptionEnginePolicy.targetsBuiltInTranslation("Spanish"))
        XCTAssertFalse(CaptionEnginePolicy.targetsBuiltInTranslation("english speaker"))
    }
}

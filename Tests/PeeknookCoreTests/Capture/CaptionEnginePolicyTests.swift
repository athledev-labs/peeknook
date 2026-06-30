// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure routing leaf: the single-pass translate route is taken ONLY when the target is English AND the
/// engine can translate in its own pass. The baseline (non-translating) engine always transcribes, so an
/// English target can never show untranslated text. The plan carries the source locale through untouched.
final class CaptionEnginePolicyTests: XCTestCase {
    private let source = Locale(identifier: "ko-KR")

    private func directive(_ target: String) -> TranslationDirective {
        TranslationDirective(targetLanguage: target)
    }

    func testEnglishTargetWithTranslateCapableEngineRoutesToSinglePass() {
        for label in ["English", "english", "  EN  ", "en-US", "eng", "English (UK)"] {
            let plan = CaptionEnginePolicy.plan(target: directive(label), sourceLocale: source, engineTranslatesToEnglish: true)
            XCTAssertEqual(plan.mode, .translateToEnglish, "\(label) + a translate-capable engine should take the single-pass route")
            XCTAssertTrue(plan.producesTargetLanguage)
        }
    }

    /// The load-bearing correctness case: with the baseline (SFSpeech) engine that cannot translate, an
    /// English target must STILL transcribe (and let the LLM translate) — never skip the pass and show raw
    /// source text.
    func testEnglishTargetWithBaselineEngineStaysTranscribe() {
        let plan = CaptionEnginePolicy.plan(target: directive("English"), sourceLocale: source, engineTranslatesToEnglish: false)
        XCTAssertEqual(plan.mode, .transcribe)
        XCTAssertFalse(plan.producesTargetLanguage)
    }

    func testNonEnglishTargetAlwaysTranscribes() {
        for label in ["German", "Korean", "español", "français", "Englishman", "Pidgin English", ""] {
            // Even a translate-capable engine only translates to English, so any other target transcribes.
            let plan = CaptionEnginePolicy.plan(target: directive(label), sourceLocale: source, engineTranslatesToEnglish: true)
            XCTAssertEqual(plan.mode, .transcribe, "\(label) should transcribe for the LLM pass")
            XCTAssertFalse(plan.producesTargetLanguage)
        }
    }

    func testPlanCarriesSourceLocaleThrough() {
        let plan = CaptionEnginePolicy.plan(target: directive("German"), sourceLocale: source, engineTranslatesToEnglish: true)
        XCTAssertEqual(plan.sourceLocale, source)
    }

    func testTargetsBuiltInTranslationIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(CaptionEnginePolicy.targetsBuiltInTranslation(" English "))
        XCTAssertTrue(CaptionEnginePolicy.targetsBuiltInTranslation("EN"))
        XCTAssertFalse(CaptionEnginePolicy.targetsBuiltInTranslation("Spanish"))
        XCTAssertFalse(CaptionEnginePolicy.targetsBuiltInTranslation("english speaker"))
    }
}

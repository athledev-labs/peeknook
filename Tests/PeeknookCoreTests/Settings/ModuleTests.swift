// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class ModuleTests: XCTestCase {
    func testFlatBooleanModulesReadThroughSettings() {
        var settings = PeeknookSettings()
        settings.webLookupEnabled = true
        settings.voiceInputEnabled = false
        settings.speakAnswersEnabled = true
        settings.persistConversation = false
        settings.suggestFollowUps = true

        let profile = GroundProfile.screenDefault
        XCTAssertTrue(Module.isEnabled(.webLookup, in: settings, profile: profile))
        XCTAssertFalse(Module.isEnabled(.voiceInput, in: settings, profile: profile))
        XCTAssertTrue(Module.isEnabled(.speakAnswers, in: settings, profile: profile))
        XCTAssertFalse(Module.isEnabled(.saveConversation, in: settings, profile: profile))
        XCTAssertTrue(Module.isEnabled(.suggestFollowUps, in: settings, profile: profile))
    }

    func testGroundDerivedModulesFollowActiveGrounds() {
        let settings = PeeknookSettings()
        let screen = GroundProfile.screenDefault
        XCTAssertTrue(Module.isEnabled(.screenCapture, in: settings, profile: screen))
        XCTAssertTrue(Module.isEnabled(.selectedText, in: settings, profile: screen))
        XCTAssertFalse(Module.isEnabled(.cameraCapture, in: settings, profile: screen))
    }

    func testAgentActionsModuleIsNeverEnabled() {
        let settings = PeeknookSettings()
        let profile = GroundProfile.screenDefault
        XCTAssertFalse(Module.isEnabled(.agentActions, in: settings, profile: profile))
    }

    func testParallelScreenFollowsCompositeCaptureSetting() {
        var settings = PeeknookSettings()
        let profile = GroundProfile.screenDefault
        XCTAssertFalse(Module.isEnabled(.parallelScreen, in: settings, profile: profile), "off by default")
        settings.compositeCaptureEnabled = true
        XCTAssertTrue(Module.isEnabled(.parallelScreen, in: settings, profile: profile), "on when the user opts in")
    }

    func testLiveSessionFollowsLiveEnabledSetting() {
        var settings = PeeknookSettings()
        let profile = GroundProfile.screenDefault
        XCTAssertFalse(Module.isEnabled(.liveSession, in: settings, profile: profile), "off by default")
        settings.liveEnabled = true
        XCTAssertTrue(Module.isEnabled(.liveSession, in: settings, profile: profile), "on when the user opts in")
    }

    func testLiveCaptionFollowsCaptionEnabledSetting() {
        var settings = PeeknookSettings()
        let profile = GroundProfile.screenDefault
        XCTAssertFalse(Module.isEnabled(.liveCaption, in: settings, profile: profile), "off by default")
        settings.captionEnabled = true
        XCTAssertTrue(Module.isEnabled(.liveCaption, in: settings, profile: profile), "on when the user opts in")
    }
}

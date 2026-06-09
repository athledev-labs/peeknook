// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Pure-logic guard for the command bar's reactive behaviour — the visibility, disabled, toggled-face
/// and prominence decisions a `PeekCommandBar` renders. These are exactly the things a bar refactor
/// can silently regress (a lost `.disabled`, a Speak button stuck on "Speak", a pill shown in the
/// wrong state) and that `swift test` can otherwise not see, so they are asserted here at the data
/// layer, against the real ``CommandLayout/screenDefault``.
final class CommandBarResolutionTests: XCTestCase {
    private let layout = CommandLayout.screenDefault

    // MARK: Capability gating — permissions disable, modules hide

    func testCaptureIsDisabledUntilReadyButStaysVisible() {
        let capture = descriptor("idle.capture")
        XCTAssertTrue(capture.isDisabled(in: ctx(isReady: false)))
        XCTAssertFalse(capture.isDisabled(in: ctx(isReady: true)))
        // Disabled is not hidden — Capture renders in both states.
        XCTAssertTrue(capture.isVisible(in: ctx(isReady: false, enabledModules: [.screenCapture])))
    }

    func testSpeakHiddenWithoutItsModule() {
        let speak = descriptor("result.speak")
        XCTAssertFalse(speak.isVisible(in: ctx(enabledModules: [])))
        XCTAssertTrue(speak.isVisible(in: ctx(enabledModules: [.speakAnswers])))
    }

    func testNonPermissionCommandsAreNeverDisabled() {
        for command in layout.commands where command.requiredPermissions.isEmpty {
            XCTAssertFalse(command.isDisabled(in: ctx(isReady: false)), "\(command.id) should not disable")
        }
    }

    // MARK: Transient visibility

    func testResumeVisibilityTracksPreview() {
        let resume = descriptor("idle.resume")
        XCTAssertFalse(resume.isVisible(in: ctx(hasResumePreview: false)))
        XCTAssertTrue(resume.isVisible(in: ctx(hasResumePreview: true)))
    }

    func testUseThisOnlyWhilePreviewingCancelAlways() {
        let useThis = descriptor("active.useThis")
        let cancel = descriptor("active.cancel")
        XCTAssertEqual(layout.visibleCommands(.active, in: ctx(isPreviewing: true)).map(\.id),
                       ["active.useThis", "active.cancel"])
        XCTAssertEqual(layout.visibleCommands(.active, in: ctx(isPreviewing: false)).map(\.id),
                       ["active.cancel"])
        XCTAssertTrue(useThis.isVisible(in: ctx(isPreviewing: true)))
        XCTAssertFalse(useThis.isVisible(in: ctx(isPreviewing: false)))
        XCTAssertTrue(cancel.isVisible(in: ctx(isPreviewing: false)))
    }

    func testHistoryAndExportVisibility() {
        XCTAssertFalse(descriptor("result.history").isVisible(in: ctx(hasConversationHistory: false)))
        XCTAssertTrue(descriptor("result.history").isVisible(in: ctx(hasConversationHistory: true)))
        XCTAssertFalse(descriptor("result.export").isVisible(in: ctx(showingFullConversation: false)))
        XCTAssertTrue(descriptor("result.export").isVisible(in: ctx(showingFullConversation: true)))
    }

    // MARK: Toggled appearance (face swap) is independent of prominence

    func testBriefSymbolFillsOnContentNotOnComposer() {
        let brief = descriptor("idle.brief")
        // Composer open but brief empty: symbol stays outline (matches today's `sessionBrief.isEmpty`).
        let composingEmpty = ctx(briefHasContent: false, briefComposerVisible: true)
        XCTAssertEqual(brief.resolvedSymbol(in: composingEmpty), "text.alignleft")
        XCTAssertTrue(brief.isProminent(in: composingEmpty), "open composer accents Brief")
        // Brief has content: symbol fills and it is prominent.
        let briefed = ctx(briefHasContent: true, briefComposerVisible: false)
        XCTAssertEqual(brief.resolvedSymbol(in: briefed), "text.alignleft.fill")
        XCTAssertTrue(brief.isProminent(in: briefed))
        // Idle, no brief: outline, not prominent.
        XCTAssertEqual(brief.resolvedSymbol(in: ctx()), "text.alignleft")
        XCTAssertFalse(brief.isProminent(in: ctx()))
    }

    func testSpeakSwapsTitleSymbolHelpButNeverAccents() {
        let speak = descriptor("result.speak")
        let speaking = ctx(isSpeaking: true, enabledModules: [.speakAnswers])
        XCTAssertEqual(speak.resolvedTitleKey(in: speaking), "Stop")
        XCTAssertEqual(speak.resolvedSymbol(in: speaking), "stop.fill")
        XCTAssertEqual(speak.resolvedHelpKey(in: speaking), "Stop reading the answer aloud")
        XCTAssertFalse(speak.isProminent(in: speaking), "Speak/Stop never becomes prominent")
        let idleSpeak = ctx(enabledModules: [.speakAnswers])
        XCTAssertEqual(speak.resolvedTitleKey(in: idleSpeak), "Speak")
        XCTAssertEqual(speak.resolvedSymbol(in: idleSpeak), "speaker.wave.2")
    }

    func testHistoryFlipsHelpAndProminenceWhenExpanded() {
        let history = descriptor("result.history")
        let expanded = ctx(hasConversationHistory: true, showingFullConversation: true)
        XCTAssertEqual(history.resolvedHelpKey(in: expanded), "Show only the latest answer")
        XCTAssertTrue(history.isProminent(in: expanded))
        let collapsed = ctx(hasConversationHistory: true, showingFullConversation: false)
        XCTAssertEqual(history.resolvedHelpKey(in: collapsed), "View the full conversation thread")
        XCTAssertFalse(history.isProminent(in: collapsed))
    }

    func testFollowUpAccentsWhileComposingWithoutAFace() {
        let followUp = descriptor("result.followUp")
        XCTAssertNil(followUp.alternateFace)
        XCTAssertTrue(followUp.isProminent(in: ctx(followUpComposerVisible: true)))
        XCTAssertFalse(followUp.isProminent(in: ctx(followUpComposerVisible: false)))
    }

    // MARK: A representative idle render set

    func testIdleVisibleSetWithResumeAndReady() {
        let context = ctx(isReady: true, hasResumePreview: true, enabledModules: [.screenCapture])
        XCTAssertEqual(
            layout.visibleCommands(.idle, in: context).map(\.id),
            ["idle.resume", "idle.brief", "idle.model", "idle.depth", "idle.scope", "idle.capture"]
        )
        // Without a resume preview the bar drops Resume and keeps order.
        let noResume = ctx(enabledModules: [.screenCapture])
        XCTAssertEqual(
            layout.visibleCommands(.idle, in: noResume).map(\.id),
            ["idle.brief", "idle.model", "idle.depth", "idle.scope", "idle.capture"]
        )
    }

    // MARK: Helpers

    private func ctx(
        isPreviewing: Bool = false,
        isReady: Bool = true,
        hasResumePreview: Bool = false,
        hasConversationHistory: Bool = false,
        showingFullConversation: Bool = false,
        isSpeaking: Bool = false,
        briefHasContent: Bool = false,
        briefComposerVisible: Bool = false,
        followUpComposerVisible: Bool = false,
        enabledModules: Set<ModuleID> = []
    ) -> CommandBarContext {
        CommandBarContext(
            isPreviewing: isPreviewing, isReady: isReady, hasResumePreview: hasResumePreview,
            hasConversationHistory: hasConversationHistory, showingFullConversation: showingFullConversation,
            isSpeaking: isSpeaking, briefHasContent: briefHasContent, briefComposerVisible: briefComposerVisible,
            followUpComposerVisible: followUpComposerVisible, enabledModules: enabledModules
        )
    }

    private func descriptor(_ id: String) -> CommandDescriptor {
        guard let match = layout.commands.first(where: { $0.id == id }) else {
            XCTFail("no descriptor with id \(id)"); return layout.commands[0]
        }
        return match
    }
}

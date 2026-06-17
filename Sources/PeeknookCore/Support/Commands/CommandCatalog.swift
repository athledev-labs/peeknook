// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Built-in layout (the migration anchor: reproduces today's exact idle / active / result bars)

public extension CommandLayout {
    /// The shipped layout. Mirrors, command-for-command and in order, the three hardcoded surfaces at
    /// HEAD — `PeekIdleCommandBar` (Resume · Brief · Model ▾ · Depth ▾ · Scope ▾ · Capture),
    /// `PeekHomeActiveControls` (Use this · Cancel), and `PeekHomeResultView.resultCommandBar`
    /// (History · Export · Brief · Follow up · Speak · Done · New chat). This equivalence is the
    /// Phase 1.5 migration anchor; ``CommandLayoutTests`` guards it.
    static let screenDefault = CommandLayout(commands: [
        // ── Idle bar ──────────────────────────────────────────────────────────────────────────
        CommandDescriptor(
            id: "idle.resume", kind: .button, action: .resume,
            titleKey: "Resume", symbol: "arrow.uturn.backward",
            placement: .idle, visibility: .hasResumePreview, defaultOrder: 0
        ),
        CommandDescriptor(
            id: "idle.brief", kind: .button, action: .brief,
            titleKey: "Brief", symbol: "text.alignleft",
            alternateFace: CommandFace(symbol: "text.alignleft.fill"),
            hotkey: .settingsSlot(.brief),
            placement: .idle, defaultOrder: 1
        ),
        CommandDescriptor(
            id: "idle.model", kind: .valueDropdown(.model), action: nil,
            titleKey: "Answer model", symbol: "cpu",
            helpKey: "Answer model for the next capture",
            placement: .idle, defaultOrder: 2
        ),
        CommandDescriptor(
            id: "idle.depth", kind: .valueDropdown(.depth), action: nil,
            titleKey: "Answer depth", symbol: "hare",
            helpKey: "Answer depth for the next capture",
            placement: .idle, defaultOrder: 3
        ),
        CommandDescriptor(
            id: "idle.scope", kind: .valueDropdown(.scope), action: nil,
            titleKey: "Capture area", symbol: "macwindow",
            helpKey: "Capture target for the next capture",
            placement: .idle, defaultOrder: 4
        ),
        CommandDescriptor(
            id: "idle.importFile", kind: .button, action: .importFile,
            titleKey: "Import file", symbol: "doc.badge.plus",
            helpKey: "Open a PDF or image from disk to ask about",
            placement: .idle, defaultOrder: 5
        ),
        CommandDescriptor(
            id: "idle.compositeCapture", kind: .button, action: .compositeCapture,
            titleKey: "Screen + camera", symbol: "photo.on.rectangle.angled",
            helpKey: "Capture your screen and a camera photo for one question",
            placement: .idle,
            requiredModules: [.parallelScreen, .screenCapture],
            requiredPermissions: [.screenRecording, .camera],
            defaultOrder: 7
        ),
        CommandDescriptor(
            id: "idle.capture", kind: .button, action: .capture,
            titleKey: "Capture", symbol: "camera.viewfinder",
            helpKey: "Instant capture from anywhere on your Mac",
            hotkey: .settingsSlot(.capture),
            placement: .idle, pinnedTrailing: true, prominent: true,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],
            defaultOrder: 6
        ),
        // Idle Stop — only reachable when a Live session persisted across Done (`livePersistAcrossDone`),
        // so the armed thread is one-tap disarmable from the home screen. Mirrors `result.stopLive`: no
        // `requiredModules` (the sole disarm control must never be module-gated while armed) and
        // `action == .stopLive` makes it non-customizable for free (Layout can never hide it).
        CommandDescriptor(
            id: "idle.stopLive", kind: .button, action: .stopLive,
            titleKey: "Stop", symbol: "stop.circle",
            helpKey: "Stop the live session",
            placement: .idle, visibility: .liveArmed, defaultOrder: 8
        ),

        // ── Active controls (post-capture confirm) ────────────────────────────────────────────
        CommandDescriptor(
            id: "active.useThis", kind: .button, action: .confirmPreview,
            titleKey: "Use this", symbol: "checkmark.circle",
            placement: .active, prominent: true, visibility: .previewing, defaultOrder: 0
        ),
        CommandDescriptor(
            id: "active.cancel", kind: .button, action: .cancel,
            titleKey: "Cancel", symbol: "xmark",
            placement: .active, defaultOrder: 1
        ),

        // ── Result bar ────────────────────────────────────────────────────────────────────────
        CommandDescriptor(
            id: "result.history", kind: .button, action: .history,
            titleKey: "History", symbol: "clock.arrow.circlepath",
            alternateFace: CommandFace(helpKey: "Show only the latest answer"),
            helpKey: "View the full conversation thread",
            placement: .result, visibility: .hasConversationHistory, defaultOrder: 0
        ),
        CommandDescriptor(
            id: "result.export", kind: .button, action: .export,
            titleKey: "Copy thread", symbol: "doc.on.doc",
            helpKey: "Copy the whole thread as Markdown",
            placement: .result, visibility: .showingFullConversation, defaultOrder: 1
        ),
        CommandDescriptor(
            id: "result.brief", kind: .button, action: .brief,
            titleKey: "Brief", symbol: "text.alignleft",
            alternateFace: CommandFace(symbol: "text.alignleft.fill"),
            hotkey: .settingsSlot(.brief),
            placement: .result, defaultOrder: 2
        ),
        CommandDescriptor(
            id: "result.followUp", kind: .button, action: .followUp,
            titleKey: "Follow up", symbol: "bubble.left.and.bubble.right",
            helpKey: "Ask a follow-up about this answer",
            placement: .result, defaultOrder: 3
        ),
        CommandDescriptor(
            id: "result.retake", kind: .button, action: .retake,
            titleKey: "Retake", symbol: "arrow.triangle.2.circlepath.camera",
            helpKey: "Capture a new screenshot and replace this chat",
            placement: .result,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],
            defaultOrder: 4
        ),
        CommandDescriptor(
            id: "result.addImage", kind: .button, action: .addImage,
            titleKey: "Add image", symbol: "photo.badge.plus",
            helpKey: "Capture another screenshot and add it to this chat",
            hotkey: .settingsSlot(.capture),
            placement: .result,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],
            defaultOrder: 5
        ),
        CommandDescriptor(
            id: "result.compositeCapture", kind: .button, action: .compositeCapture,
            titleKey: "Screen + camera", symbol: "photo.on.rectangle.angled",
            helpKey: "Add a screen and camera photo to this chat as one question",
            placement: .result,
            requiredModules: [.parallelScreen, .screenCapture],
            requiredPermissions: [.screenRecording, .camera],
            defaultOrder: 9
        ),
        CommandDescriptor(
            id: "result.speak", kind: .button, action: .speak,
            titleKey: "Speak", symbol: "speaker.wave.2",
            alternateFace: CommandFace(titleKey: "Stop", symbol: "stop.fill", helpKey: "Stop reading the answer aloud"),
            helpKey: "Read the answer aloud",
            placement: .result, visibility: .always,
            requiredModules: [.speakAnswers], defaultOrder: 6
        ),
        CommandDescriptor(
            id: "result.toggleLive", kind: .button, action: .toggleLive,
            titleKey: "Go live", symbol: "dot.radiowaves.left.and.right",
            helpKey: "Keep this chat live so it stays in context across captures",
            placement: .result, visibility: .liveDisarmed,
            requiredModules: [.liveSession],
            defaultOrder: 10
        ),
        CommandDescriptor(
            id: "result.refreshLive", kind: .button, action: .refreshLive,
            titleKey: "Refresh", symbol: "arrow.clockwise",
            helpKey: "Capture the latest screen into this live chat",
            placement: .result, visibility: .liveArmed,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],
            defaultOrder: 11
        ),
        CommandDescriptor(
            id: "result.answerNow", kind: .button, action: .answerLive,
            titleKey: "Answer now", symbol: "arrow.up.message",
            helpKey: "Answer from the latest screen Peek already grabbed",
            placement: .result, visibility: .liveHasPendingFrame,
            requiredModules: [.liveSession],   // no permission gate: it answers a frame already captured
            defaultOrder: 12
        ),
        CommandDescriptor(
            id: "result.updateAndAsk", kind: .button, action: .updateAndAskLive,
            titleKey: "Update & ask", symbol: "arrow.clockwise.circle",
            helpKey: "Capture the latest screen and answer in one step",
            placement: .result, visibility: .liveArmed,
            requiredModules: [.screenCapture], requiredPermissions: [.screenRecording],   // it re-captures
            defaultOrder: 13
        ),
        CommandDescriptor(
            id: "result.stopLive", kind: .button, action: .stopLive,
            titleKey: "Stop", symbol: "stop.circle",
            helpKey: "Stop the live session",
            placement: .result, visibility: .liveArmed, defaultOrder: 14
        ),
        CommandDescriptor(
            id: "result.done", kind: .button, action: .done,
            titleKey: "Done", symbol: "house",
            helpKey: "End this chat and return to the home screen",
            placement: .result, pinnedTrailing: true, prominent: true, defaultOrder: 7
        ),
        CommandDescriptor(
            id: "result.newChat", kind: .button, action: .newChat,
            titleKey: "New chat", symbol: "arrow.counterclockwise",
            helpKey: "Discard this thread and start fresh",
            placement: .result, defaultOrder: 8
        ),
    ])

    /// The camera profile's layout: everything from ``screenDefault`` plus the `.cameraLive`
    /// Shutter / Cancel group. A separate layout — `screenDefault` itself never gains `.cameraLive`
    /// descriptors (its empty `.cameraLive` placement is the Phase 1.5 migration anchor).
    ///
    /// Cancel deliberately carries **no** module or permission gate: a live camera surface must
    /// never render without an exit, whatever the active profile or TCC state. Shutter gates on
    /// the camera module + permission; the renderer resolves both against the `camera.study`
    /// profile literal (the single profile-source rule), not the active profile.
    static let cameraStudy = CommandLayout(commands: screenDefault.commands + [
        CommandDescriptor(
            id: "cameraLive.cancel", kind: .button, action: .cancel,
            titleKey: "Cancel", symbol: "xmark",
            placement: .cameraLive, defaultOrder: 0
        ),
        CommandDescriptor(
            id: "cameraLive.shutter", kind: .button, action: .shutter,
            titleKey: "Shutter", symbol: "circle.inset.filled",
            helpKey: "Capture a photo from the camera",
            hotkey: .settingsSlot(.camera),
            placement: .cameraLive, pinnedTrailing: true, prominent: true,
            requiredModules: [.cameraCapture], requiredPermissions: [.camera],
            defaultOrder: 1
        ),
    ])
}

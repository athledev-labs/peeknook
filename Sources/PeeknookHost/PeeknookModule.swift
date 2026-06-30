// SPDX-License-Identifier: Apache-2.0

import Foundation
import NookApp
import PeeknookCore
import PeeknookUI
import PeeknookWhisper
import SwiftUI

/// Quiet contextual label for the home top bar, breadcrumb drill-ins still win.
private enum PeekTopBarDate {
    nonisolated static func label() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return formatter.string(from: Date())
    }
}

/// Peeknook practice copilot, one module in a multi-module OpenNook host.
@MainActor
public final class PeeknookModule: NookModule {
    nonisolated public static let moduleDescriptor = NookModuleDescriptor(
        id: PeeknookModuleID.peeknook,
        displayName: "Peeknook",
        icon: "sparkles.rectangle.stack",
        accent: .teal,
        backgroundPolicy: .stayResident
    )

    public let descriptor = PeeknookModule.moduleDescriptor
    private let context: NookModuleContext
    private let orchestrator: SessionOrchestrator
    private let setup: SetupCoordinator
    private let usage: UsageStore
    private let settings: PeekSettingsController
    private let modelCatalog: ModelCatalogService
    private let storageFootprint: any StorageFootprinting
    private weak var appCoordinator: AppCoordinator?
    private var previewPhaseTask: Task<Void, Never>?
    private var previewPinHandle: NookPresentationPinHandle?
    /// The user's `keepNookOpen` preference saved while a caption holds the nook latched open, restored
    /// when the caption ends. Non-nil ONLY for the life of a `.captioning` surface. See the caption
    /// keep-open latch in ``startPreviewPhaseHandling(on:)``.
    private var captionKeepNookOpenSaved: Bool?

    public init(context: NookModuleContext) {
        self.context = context
        var loaded = PeeknookSettings.load(from: context.defaults)
        let dependencies: PeeknookDependencies
        if PeeknookTestMode.isEnabled {
            loaded.previewBeforeInfer = false
            dependencies = PeeknookDependencies.testing(
                capture: StubCaptureProvider(sampleText: "uitest screen"),
                inference: MockInferenceEngine(tokens: ["test", " answer"]),
                conversationArchive: ConversationArchiveStore.makeForTesting(),
                cameraSession: StubCameraSession()
            )
        } else {
            // Inject the on-device Whisper caption engine. Constructing it is cheap and side-effect-free
            // beyond kicking a background model load; it stays dormant until the user enables captions.
            dependencies = .production(streamingTranscriberOverride: WhisperKitStreamingTranscriber())
        }
        let stack = PeeknookServices.makeStack(
            settings: loaded,
            defaults: context.defaults,
            dependencies: dependencies
        )
        if PeeknookTestMode.isEnabled {
            stack.setup.applyTestBypass()
        }
        self.orchestrator = stack.orchestrator
        self.setup = stack.setup
        self.usage = stack.usage
        self.settings = stack.settings
        self.modelCatalog = stack.modelCatalog
        self.storageFootprint = stack.storageFootprint
    }

    public func makeConfiguration() -> NookConfiguration {
        var configuration = NookConfiguration()
        configuration.setHome {
            PeekRootView(
                orchestrator: self.orchestrator,
                setup: self.setup,
                settings: self.settings,
                modelCatalog: self.modelCatalog
            )
        }
        configuration.setCompactTrailing {
            PeekCompactView(
                orchestrator: self.orchestrator,
                setup: self.setup,
                onExpand: { [weak self] in
                    guard let coordinator = self?.appCoordinator else { return }
                    coordinator.showHome()
                    coordinator.showNook()
                }
            )
        }
        configuration.setSettings {
            PeekSettingsView(
                orchestrator: self.orchestrator,
                setup: self.setup,
                settings: self.settings,
                modelCatalog: self.modelCatalog,
                usage: self.usage,
                storageFootprint: self.storageFootprint,
                onCaptureHotkeyChange: { [weak self] _ in
                    guard let self, let coordinator = self.appCoordinator else { return }
                    self.registerHotkeys(on: coordinator)
                },
                onBriefHotkeyChange: { [weak self] _ in
                    guard let self, let coordinator = self.appCoordinator else { return }
                    self.registerHotkeys(on: coordinator)
                },
                onCameraHotkeyChange: { [weak self] _ in
                    guard let self, let coordinator = self.appCoordinator else { return }
                    self.registerHotkeys(on: coordinator)
                }
            )
        }
        // Date is ambient home chrome only, drilled-in surfaces (Settings, module
        // breadcrumb) use a stable back label so the route reads "Home › Settings",
        // not "Friday, Jun 5 › Settings".
        configuration.topBar.leadingTitle = { appState in
            let hasBreadcrumb = appState.moduleBreadcrumb?.isEmpty == false
            if appState.isSettingsView || hasBreadcrumb {
                return "Home"
            }
            return PeekTopBarDate.label()
        }
        // Peeknook's module glyph, not the default OpenNook notch mark (see NookMarkView).
        configuration.topBar.leadingIcon = Self.moduleDescriptor.icon
        configuration.topBar.width = .contentColumn
        configuration.expandedWidth = 600
        configuration.style = NookStyle(
            topCornerRadius: 19,
            bottomCornerRadius: 24,
            expandedContentInsets: NookEdgeInsets(top: 0, bottom: 2, leading: 8, trailing: 8)
        )
        configuration.theme = { appState in
            var theme = NookResolvedTheme.live(appState: appState)
            if appState.appearancePreferences.accentPreset == .system {
                theme.accent = Self.moduleDescriptor.accent
            }
            return theme
        }
        // Global (always-available, app-level) actions live in the chrome's trailing top-bar
        // cluster next to the lock/gear; phase- and thread-specific actions stay in the in-content
        // bottom command bars. See PeekGlobalTopBarItems for the top/bottom placement rule.
        configuration.setTopBarTrailingItems {
            PeekGlobalTopBarItems(orchestrator: self.orchestrator)
        }
        // PRIVACY KILL-PATH: nook-collapse and hide are NOT phase changes, so the phase-observation
        // loop below can never see them. These hooks fire the camera cancel unconditionally — it is
        // a no-op outside `.cameraLive` and idempotent against the loop's own pin release. Without
        // this, a `.stayResident` module would keep the camera running with no visible UI.
        // They ALSO disarm any live session: a continuous capture must never linger with no visible chip.
        //
        // CAPTION EXCEPTION (collapse only): a live caption's whole purpose is to subtitle ANOTHER window
        // you are watching, and watching it means clicking away from the notch — so a collapse must NOT
        // end it. While captioning, `onCompact` keeps the tap armed and RE-ASSERTS the surface open, so
        // the caption stays always-indicated and still bounded by its mandatory cap + Stop. (The phase
        // loop also latches `keepNookOpen` for the life of the surface, so a hover-exit normally never
        // compacts at all; this is the belt-and-suspenders for an explicit collapse.) `onHide` and
        // `prepareForSwitchAway` still HARD-disarm the caption: a hidden nook or another module's surface
        // cannot keep it indicated, so it must end, exactly like the camera.
        configuration.onCompact = { [weak self] in
            guard let self else { return }
            self.orchestrator.cancelCameraLive()
            if self.orchestrator.isCaptioning {
                self.appCoordinator?.showHome()   // re-open; keep the caption armed + indicated
                return
            }
            self.orchestrator.stopLiveSession()
            self.orchestrator.stopCaption()
        }
        configuration.onHide = { [weak self] in
            self?.orchestrator.cancelCameraLive()
            self?.orchestrator.stopLiveSession()
            self?.orchestrator.stopCaption()
        }
        configuration.onReady = { [weak self] coordinator in
            self?.registerHotkeys(on: coordinator)
            self?.startPreviewPhaseHandling(on: coordinator)
            // Accessory apps have no main menu, so ⌘A/⌘C/⌘V/⌘X/⌘Z don't reach text fields.
            StandardEditMenu.installIfNeeded()
            if PeeknookTestMode.isEnabled {
                coordinator.showHome()
                coordinator.showNook()
                if PeeknookTestMode.opensSettingsOnLaunch {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        coordinator.showSettings()
                    }
                }
            }
        }
        return configuration
    }

    private func registerHotkeys(on coordinator: AppCoordinator) {
        appCoordinator = coordinator
        registerCaptureHotkey(on: coordinator)
        registerBriefHotkey(on: coordinator)
        registerCameraHotkey(on: coordinator)
    }

    private func registerCaptureHotkey(on coordinator: AppCoordinator) {
        let captureID = "peeknook.capture"
        let stored = orchestrator.settings.captureHotkey
        _ = coordinator.hotkeyController.register(
            captureID,
            keyCode: stored.keyCode,
            modifiers: stored.carbonModifiers
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                coordinator.showHome()
                coordinator.showNook()
                self.setup.refreshCapturePermission()
                self.orchestrator.beginCapture()
            }
        }
    }

    private func registerBriefHotkey(on coordinator: AppCoordinator) {
        let briefID = "peeknook.brief"
        let stored = orchestrator.settings.briefHotkey
        _ = coordinator.hotkeyController.register(
            briefID,
            keyCode: stored.keyCode,
            modifiers: stored.carbonModifiers
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                coordinator.showHome()
                coordinator.showNook()
                self.orchestrator.focusBriefComposer()
            }
        }
    }

    private func registerCameraHotkey(on coordinator: AppCoordinator) {
        let cameraID = "peeknook.camera"
        let stored = orchestrator.settings.cameraHotkey
        _ = coordinator.hotkeyController.register(
            cameraID,
            keyCode: stored.keyCode,
            modifiers: stored.carbonModifiers
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                coordinator.showHome()
                coordinator.showNook()
                self.orchestrator.openCameraLive()
            }
        }
    }

    /// Pin the nook open while a phase needs the panel on screen — the post-capture confirm
    /// (`.previewing`), the live camera (`.cameraLive`), and the live caption surface
    /// (`.captioning`) — expanding to Home on entry and releasing the pin on exit. A continuous
    /// caption MUST stay indicated, so its panel is pinned exactly like the live camera. This loop
    /// observes *phase changes only*: collapse/hide are driven by the configuration's
    /// `onCompact`/`onHide` hooks (see `makeConfiguration`), which disarm the camera/caption and
    /// thereby move the phase, after which this loop releases the pin.
    private func startPreviewPhaseHandling(on coordinator: AppCoordinator) {
        previewPhaseTask?.cancel()
        previewPhaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let pinning = context.services.resolve(NookPresentationPinningKey.self)
            enum PinnedPhase { case capturePreview, cameraLive, captioning }
            var activePin: PinnedPhase?

            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.orchestrator.phase
                    } onChange: {
                        continuation.resume()
                    }
                }

                let pinned: PinnedPhase?
                switch self.orchestrator.phase {
                case .previewing: pinned = .capturePreview
                case .cameraLive: pinned = .cameraLive
                case .captioning: pinned = .captioning
                default: pinned = nil
                }

                // CAPTION KEEP-OPEN LATCH. A caption must stay readable while you watch the window it
                // subtitles, so for the life of the `.captioning` surface force `keepNookOpen` on (saving
                // the user's prior choice) and restore it when the surface ends. This is what reliably
                // holds the nook open across a hover-exit: the presentation pin's transient override is
                // re-applied by the broker only on a ref-count edge, but `showNook()` below reprojects
                // `keepNookOpen` every time — so latching the preference is the race-free way to make the
                // surface ignore hover-exit. Set BEFORE `showNook()` (so it projects the latched value)
                // and restored BEFORE the pin release (so the broker's reset reads the restored value).
                if pinned == .captioning {
                    if captionKeepNookOpenSaved == nil {
                        captionKeepNookOpenSaved = coordinator.appState.keepNookOpen
                        coordinator.appState.keepNookOpen = true
                    }
                } else if let saved = captionKeepNookOpenSaved {
                    coordinator.appState.keepNookOpen = saved
                    captionKeepNookOpenSaved = nil
                }

                if let pinned, pinned != activePin {
                    coordinator.showHome()
                    coordinator.showNook()
                    previewPinHandle?.release()
                    switch pinned {
                    case .capturePreview: previewPinHandle = pinning.pin(reason: "capture-preview")
                    case .cameraLive: previewPinHandle = pinning.pin(reason: "camera-live")
                    case .captioning: previewPinHandle = pinning.pin(reason: "caption-surface")
                    }
                } else if pinned == nil, activePin != nil {
                    previewPinHandle?.release()
                    previewPinHandle = nil
                }

                activePin = pinned
            }
        }
    }

    /// `.stayResident` keeps this module alive across module switches — never leave the camera
    /// running, a live session armed, or a caption tap open behind another module's surface.
    public func prepareForSwitchAway() async {
        orchestrator.cancelCameraLive()
        orchestrator.stopLiveSession()
        orchestrator.stopCaption()
        // Restore the caption keep-open latch eagerly: switching to another module's surface can take over
        // before the phase loop observes the disarm, and that module must not inherit a forced-open nook.
        if let saved = captionKeepNookOpenSaved {
            appCoordinator?.appState.keepNookOpen = saved
            captionKeepNookOpenSaved = nil
        }
    }
}

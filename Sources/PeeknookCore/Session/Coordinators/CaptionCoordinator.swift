// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The `.captioning` flow: an EPHEMERAL on-device transcription → translated-subtitle surface. Unlike
/// every other coordinator it is **non-committing** — it never touches `conversation`, the archive, the
/// blob store, usage, suggestions, or speech. Each finalized transcript segment drives a one-shot,
/// throwaway inference whose tokens stream into `liveCaption.currentLine`; nothing is persisted, so no
/// transcript can reach disk.
///
/// Privacy invariants it enforces (invariant 5 — every continuous experience is bounded + indicated):
///  - **Local-only by default.** The translate route is refused AT ARM TIME when it would egress to a
///    remote host / `:cloud` tag, unless the active profile opted in (`captionAllowRemote`) — the
///    screen-secret redactor does not cover conversational audio PII, so audio never leaves the Mac by
///    default.
///  - **Always bounded.** Arming snapshots a mandatory auto-disarm deadline (reusing `livePolicy` + the
///    Live timer loop) the user cannot disable, plus a silence timeout that ends a tap whose audio went
///    away. Audio is never a user interaction, so neither bound is reset by hearing more sound.
///  - **Always indicated + disarmed on every exit EXCEPT a bare collapse.** Teardown funnels through
///    ``clearCaptionSurface()`` (the single idempotent choke point, mirroring
///    ``CameraCoordinator/stopCameraPreview()``), folded into ``SessionOrchestrator/stopLiveSession()`` so
///    every disarm path (Stop, New chat, switch/delete thread, hide, switch-away, the mandatory cap) tears
///    the tap down. A nook COLLAPSE is the one sanctioned exception (product decision): a caption
///    subtitles another window you are watching, so the host re-asserts the surface open and keeps the
///    tap armed on collapse instead of disarming — still always-indicated (the nook is held open) and
///    still bounded by the cap + silence timeout. See ``PeeknookModule``'s `onCompact` + keep-open latch.
///
/// Owned by ``SessionOrchestrator``; the transient `liveCaption` lives on the facade because the caption
/// view renders from it (the analogue of `activeCameraSession`).
@MainActor
final class CaptionCoordinator {
    private weak var session: SessionOrchestrator?

    /// The transcription tap's lifecycle task (start → onSegment* → throw/return). Owned HERE, cancelled
    /// only by ``clearCaptionSurface()`` — never by `abortSessionWork` (which must not disarm a caption,
    /// exactly like it must not disarm Live).
    private var captionTask: Task<Void, Never>?
    /// The in-flight translate pass for the latest finalized segment. **Latest-wins**: a newer segment
    /// supersedes a still-streaming older translation.
    private var translateTask: Task<Void, Never>?
    /// The silence watchdog: ends the surface after ``CaptionPolicy/silenceTimeout`` with no finalized
    /// segment (the audio source went away). Restarted on every finalized segment.
    private var silenceTask: Task<Void, Never>?

    /// Monotonic guard, bumped on every arm AND every teardown. A transcriber callback or a translate
    /// token that hops the main actor re-checks `generation == captured` and drops when superseded, so a
    /// late segment from a torn-down session can never mutate a fresh one's surface.
    private var generation = 0
    /// The last finalized segment's sequence — dedupes the short overlap a recognizer rollover replays.
    private var lastSequence = -1
    /// The model + endpoint resolved ONCE at arm, after the local-only egress gate passed. Every segment's
    /// ``translate(_:generation:)`` reuses this FROZEN route, so a mid-session model/profile/endpoint change
    /// can never drift the route to a remote host and bypass that arm-time gate while the tap runs
    /// (snapshot-at-arm, exactly like ``LivePolicy``'s interval/deadline). Cleared on teardown.
    private var captionRoute: RoleResolution?
    /// The transcription plan resolved ONCE at arm. The coordinator reads `producesTargetLanguage` per
    /// segment to decide whether a separate LLM translate pass runs — the SAME plan the transcriber acts
    /// on, so the engine and the coordinator never disagree about whether to translate. Cleared on teardown.
    private var captionPlan: CaptionTranscriptionPlan?

    init(session: SessionOrchestrator) {
        self.session = session
    }

    // MARK: - Arm

    /// Arm the caption surface (the "Caption" command). Legal from idle/result/failed. Refuses — WITHOUT
    /// entering the phase — when no target language is set, or when the resolved route would egress
    /// remotely without the profile opt-in (the two pure preguards, surfaced as one-shot notices).
    /// Otherwise it disarms any Live session (mutual exclusion via the shared `livePolicy`), raises the
    /// surface + mandatory deadline BEFORE the tap, then launches the on-device transcription.
    func arm() {
        guard let session else { return }
        // The master opt-in. Dormancy is enforced at the orchestrator entry point, not just by the absence
        // of a UI trigger: a future caller that wires a button without re-checking the flag still can't arm
        // captions while the feature is off. Silent — the UI never surfaces the control when off.
        guard session.settings.captionEnabled else { return }
        switch session.phase {
        case .idle, .result, .failed: break
        default: return   // a documented no-op mid-capture/preview/inferring/cameraLive/captioning
        }

        // Preguard 1: captions are translated subtitles, so a target language is required. A pure check
        // (no async, no tap) → a one-shot notice, never a phase entry.
        guard let directive = session.captionTranslationDirective else {
            session.emitNotice(.captionNeedsTargetLanguage)
            return
        }
        // Preguard 2: local-only by default. Refuse a remote / `:cloud` route unless the profile opted
        // into remote caption egress — audio PII is not covered by the screen-secret redactor, so this
        // gate is INDEPENDENT of the global remote toggle and fails closed.
        let route = session.routing(for: session.captionRole)
        let remoteEgress = route.endpoint.isRemoteEgress(modelTag: route.model.tag)
        let allowRemote = session.resolvedActiveProfile.outputConfig?.captionAllowRemote ?? false
        if remoteEgress && !allowRemote {
            session.emitNotice(.captionRemoteBlocked)
            return
        }

        // Mutual exclusion: a caption and a Live session share `livePolicy`, so disarm any armed Live
        // first. Idempotent — a no-op when nothing is armed.
        session.stopLiveSession()

        // Freeze the gated route: every segment's translate() reuses THIS, so the route the egress gate
        // just approved is the one that runs for the life of the tap (no mid-session drift). Set AFTER
        // `stopLiveSession()` (whose folded teardown clears it) so it survives into the armed session.
        captionRoute = route
        generation += 1
        lastSequence = -1
        let captured = generation
        let now = Date()

        // Raise the surface BEFORE the tap so the chip + Stop are up the instant we enter the phase.
        // Snapshot the MANDATORY auto-disarm deadline into `livePolicy` (refresh `.manual` so the Live
        // loop only ever watches the deadline — it never auto-captures; see `LiveRefreshPolicy.decide`).
        // `remoteEgressHost` lights the distinct "sending to <host>" indicator only on an opted-in route.
        session.livePolicy = LivePolicy(
            refresh: .manual,
            autoRespond: false,
            rateCap: 1,
            timerInterval: max(1, CaptionPolicy.maxArmedSeconds),
            expiresAt: now.addingTimeInterval(CaptionPolicy.maxArmedSeconds)
        )
        session.liveCaption = CaptionState(
            sourceLabel: session.captionSourceDisplayLabel,
            targetLabel: directive.targetLanguage,
            remoteEgressHost: remoteEgress ? route.endpoint.connection.baseURL : nil
        )
        guard case .applied = session.applyPhaseEvent(.openCaption) else {
            // The FSM refused (shouldn't happen given the phase guard above) — undo the surface we raised
            // so a rejected arm leaves no dangling deadline.
            session.stopLiveSession()
            return
        }
        session.lastLiveRefreshAt = now             // seed the loop's pacing clock (deadline is absolute)
        session.liveCoordinator.startTimerLoopIfNeeded()   // run the loop purely to watch the deadline
        startSilenceWatchdog()

        // Resolve the transcription plan ONCE (pure policy): an English target translates audio->English
        // in-engine in one pass; any other target transcribes the source for the per-segment LLM pass.
        let plan = CaptionEnginePolicy.plan(target: directive, sourceLocale: session.captionSourceLocale)
        captionPlan = plan
        let transcriber = session.streamingTranscriber
        captionTask = Task { [weak self] in
            do {
                try await transcriber.start(plan: plan) { [weak self] segment in
                    // The audio buffer lands off-main; hop to the main actor and re-guard generation.
                    Task { @MainActor in
                        self?.ingest(segment, generation: captured)
                    }
                } onLevel: { [weak self] level in
                    // Loudness only (no content). Same off-main hop + generation re-guard as a segment, so
                    // a level from a torn-down tap drops rather than moving a fresh session's meter.
                    Task { @MainActor in
                        self?.ingestLevel(level, generation: captured)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, let session = self.session,
                      self.generation == captured, !Task.isCancelled else { return }
                // start() failed (on-device recognition / the source-language pack unavailable, or a
                // permission off). Tear the surface down BEFORE the phase transition, then surface the
                // typed recovery card — exactly the camera's `cameraLiveFailed` ordering.
                session.stopLiveSession()
                _ = session.applyPhaseEvent(.captionFailed(SessionFailure.from(captionStartError: error)))
            }
        }
    }

    // MARK: - Segment ingestion

    /// Fold one transcriber segment into the surface. Re-guards the generation and the phase on the
    /// main-actor hop, so a callback from a torn-down or superseded tap is dropped.
    private func ingest(_ segment: TranscriptSegment, generation captured: Int) {
        guard let session, generation == captured,
              case .captioning = session.phase, session.liveCaption != nil else { return }
        if segment.isStable {
            // A finalized segment: dedupe the short overlap a recognizer rollover replays at the seam,
            // clear the "hearing…" cue, reset the silence watchdog, and fire ONE translate pass.
            guard segment.sequence > lastSequence else { return }
            lastSequence = segment.sequence
            session.liveCaption?.hearingPartial = ""
            startSilenceWatchdog()
            // When the engine already produced the target language (the single-pass translate route), show
            // its line directly — running the LLM translate pass on already-target text would only re-add
            // the per-line latency that route exists to remove. Otherwise localize via the shared seam.
            if captionPlan?.producesTargetLanguage == true {
                showTranslatedLine(segment.text)
            } else {
                translate(segment.text, generation: captured)
            }
        } else {
            // An interim hypothesis: just the source-language "hearing…" cue, replaced in place.
            session.liveCaption?.hearingPartial = segment.text
        }
    }

    /// Fold one audio-level reading into the surface meter. Loudness, not content — and bounded to a
    /// single scalar, so it can never accrete a transcript. Generation- and phase-guarded on the
    /// main-actor hop exactly like ``ingest(_:generation:)``, so a reading from a torn-down or superseded
    /// tap is dropped.
    private func ingestLevel(_ level: Float, generation captured: Int) {
        guard let session, generation == captured,
              case .captioning = session.phase, session.liveCaption != nil else { return }
        session.liveCaption?.audioLevel = level
    }

    /// Translate one finalized segment into the target language and stream the result into
    /// `currentLine`. Assembles through the SAME shared ``SessionOrchestrator/assembleRequest`` seam the
    /// answer turn uses, so the remote-egress redaction rule can never fork (the arm-time gate already
    /// fails closed for a non-opted-in remote route). Non-committing: nothing is appended to the
    /// conversation, archived, or counted in usage.
    private func translate(_ sourceText: String, generation captured: Int) {
        guard let session, let route = captionRoute else { return }
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let directive = session.captionTranslationDirective else { return }

        // Latest-wins: supersede a still-streaming older translation. Only a translation that actually
        // COMPLETED (`isTranslating == false`) is rolled into the bounded tail; a still-streaming line
        // superseded by a faster-arriving segment is partial, so drop it rather than archive a truncated
        // subtitle.
        translateTask?.cancel()
        if session.liveCaption?.isTranslating == true {
            session.liveCaption?.currentLine = ""
        } else {
            session.liveCaption?.commitCurrentLine()
        }
        session.liveCaption?.isTranslating = true
        session.liveCaption?.currentLine = ""
        // Show the recognized source line IMMEDIATELY (before the translate round-trip) so the surface
        // reads as live — the original appears at once and the translation streams in beneath it, rather
        // than the whole line blocking on the model. Overwritten by the next segment's source.
        session.liveCaption?.currentSource = trimmed

        // Build an EPHEMERAL one-turn conversation from the transcript text leg — never the real
        // conversation. The system-audio ground carries no image, so the assembled message is text-only.
        // The route is the one FROZEN at arm (post egress-gate), passed as an override so a mid-session
        // model/profile change can't drift it remote and bypass the local-only gate.
        let builder = InferenceMessageBuilder(quickMode: true, sessionBrief: nil)
        let ephemeral = [ChatTurn(id: 1, kind: .image(CaptureResult(
            text: trimmed,
            sourceLabel: "System audio",
            screenshotBase64: nil,
            ground: .systemAudio
        )))]
        let assembled = session.assembleRequest(role: session.captionRole, quickMode: true, routeOverride: route) { redaction in
            builder.inferenceMessages(from: ephemeral, translation: directive, redaction: redaction)
        }
        let endpoint = assembled.route.endpoint
        let request = assembled.request

        translateTask = Task { [weak self] in
            do {
                guard let strongSession = self?.session else { return }
                let stream = strongSession.inference(for: endpoint).stream(request: request)
                for try await event in stream {
                    if Task.isCancelled { return }
                    guard let self, let session = self.session, self.generation == captured,
                          case .captioning = session.phase else { return }
                    switch event {
                    case .token(let token):
                        session.liveCaption?.currentLine += token
                    case .completed:
                        session.liveCaption?.isTranslating = false
                        return
                    }
                }
            } catch {
                // A translate failure is non-fatal to the surface: the next segment can try. Just clear
                // the in-progress flag; a persistent failure ends the session via the silence / cap bound.
                guard let self, let session = self.session, self.generation == captured,
                      !Task.isCancelled, case .captioning = session.phase else { return }
                session.liveCaption?.isTranslating = false
            }
        }
    }

    /// Show an engine-produced TARGET-language line directly — the single-pass translate route, where the
    /// transcriber already emitted the target (auto-detecting and translating the spoken audio in one
    /// step), so there is no LLM round-trip and no separate source line to pair. Mirrors
    /// ``translate(_:generation:)``'s tail bookkeeping minus the streaming pass. Synchronous: the caller
    /// (``ingest(_:generation:)``) already re-guarded generation + phase on the main-actor hop.
    private func showTranslatedLine(_ text: String) {
        guard let session else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        translateTask?.cancel()
        session.liveCaption?.commitCurrentLine()   // roll the previous finished line into the bounded tail
        session.liveCaption?.isTranslating = false
        session.liveCaption?.currentSource = ""    // single-pass route surfaces only the target line
        session.liveCaption?.currentLine = trimmed
    }

    // MARK: - Bounds

    /// (Re)start the silence watchdog: a single-shot timer that ends the surface after
    /// ``CaptionPolicy/silenceTimeout`` with no finalized segment. A UX convenience — the mandatory cap
    /// (the Live deadline) is the load-bearing bound. Generation-guarded so a stale timer can't end a
    /// re-armed session.
    private func startSilenceWatchdog() {
        silenceTask?.cancel()
        let captured = generation
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CaptionPolicy.silenceTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, let session = self.session,
                  self.generation == captured, case .captioning = session.phase else { return }
            session.stopCaption()
            session.emitNotice(.captionEnded)
        }
    }

    // MARK: - Teardown

    /// The Stop command + the host's unconditional collapse teardown. A genuine no-op OUTSIDE
    /// `.captioning` — it never touches a Live session (disarming Live is ``SessionOrchestrator/stopLiveSession()``'s
    /// job, which the host fires separately). Phase-guarded rather than presence-guarded: the guard reads
    /// the phase, which `stopLiveSession()` does not change, so the `.cancelCaption` transition still runs
    /// after the folded teardown nils `liveCaption` (no stuck-in-`.captioning` window). The host may fire
    /// this on every collapse exactly like ``CameraCoordinator/cancelCameraLive()``.
    func stop() {
        guard let session, case .captioning = session.phase else { return }
        session.stopLiveSession()                     // clears the surface (folded) + drops `livePolicy`
        _ = session.applyPhaseEvent(.cancelCaption)   // `.captioning` → `.idle`
    }

    /// THE single caption teardown choke point — idempotent. Cancels the in-flight tap, translate, and
    /// silence tasks, bumps the generation so any in-flight main-actor-hopped callback drops, stops the
    /// transcriber, and lowers the surface. Does NOT touch the phase or `livePolicy` (mirroring
    /// ``CameraCoordinator/stopCameraPreview()``): the caller's disarm/phase transition owns those. Folded
    /// into ``SessionOrchestrator/stopLiveSession()`` so every disarm path tears the tap down. Cancelling
    /// our own `captionTask` from within it is harmless — no awaits follow at the call sites.
    func clearCaptionSurface() {
        guard let session else { return }
        // True no-op when nothing is armed (the disarm choke point fires on EVERY exit, most of which
        // aren't captioning): don't bump the generation or stop a transcriber that never started.
        guard session.liveCaption != nil || captionTask != nil else { return }
        generation += 1
        captionTask?.cancel(); captionTask = nil
        translateTask?.cancel(); translateTask = nil
        silenceTask?.cancel(); silenceTask = nil
        captionRoute = nil
        captionPlan = nil
        session.streamingTranscriber.stop()
        session.liveCaption = nil
    }
}

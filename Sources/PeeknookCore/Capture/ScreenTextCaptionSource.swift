// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(ScreenCaptureKit) && canImport(AppKit)
import ScreenCaptureKit
import AppKit
import os

/// A ``StreamingTranscribing`` conformer that reads CAPTIONS OFF THE SCREEN rather than the audio: it
/// freezes the frontmost window at arm, polls it on a steady cadence through an ``OnScreenTextReading``,
/// and emits each settled on-screen line as a stable ``TranscriptSegment``. It is the screen sibling of
/// ``RotatingSFSpeechTranscriber`` and, by sharing the SAME seam, slots behind the fuser with no
/// protocol change. It never meters audio, so — exactly as the protocol documents — it leaves `onLevel`
/// untouched and the meter rests at 0 (the fuser passes the real level through from the audio tap).
///
/// THIN ADAPTER: every DECISION is a pure, tested leaf — ``OnScreenLineExtractor`` (which line is the
/// caption), ``ScreenTextSegmentPolicy`` (when a line has settled into a new segment), and inside the
/// reader ``ScreenTextReaderPolicy`` (accessibility vs OCR). This type owns only the device glue: freeze
/// the target, the poll clock, and the off-queue read.
///
/// Concurrency mirrors the audio tap: all session state is confined to ``queue``; `stopped` is the lone
/// synchronous drop-all gate so no segment lands after ``stop()`` returns; reads are launched off-queue
/// and fold their result back ON the queue. A `reading` latch drops a tick whose predecessor's read has
/// not returned, so a slow read can never overlap itself.
final class ScreenTextCaptionSource: StreamingTranscribing, @unchecked Sendable {
    /// How often the frozen target is read. A device-glue cadence (NOT a decision — stability lives in
    /// ``ScreenTextSegmentPolicy``): brisk enough to catch a subtitle while it is up, easy enough on the
    /// machine that an OCR pass comfortably finishes between ticks.
    private static let pollInterval: TimeInterval = 0.4

    private let makeReader: @Sendable (Locale) -> any OnScreenTextReading
    private let queue = DispatchQueue(label: "com.peeknook.caption.screentext")
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    // Mutated only on `queue`.
    private var onSegment: (@Sendable (TranscriptSegment) -> Void)?
    private var reader: (any OnScreenTextReading)?
    private var target: ScreenTextTarget?
    private var ticker: DispatchSourceTimer?
    private var reading = false
    /// Bumped on every `start` AND every teardown. A poll `Task` captures the value at tick time and its
    /// result is dropped if the generation moved — so a slow read launched before a stop/re-arm can never
    /// fold stale text into (or corrupt the segment state of) a freshly armed session. The instance is
    /// reused across arm/stop cycles, so this guard is load-bearing.
    private var generation = 0

    // Segment state — touched only on `queue`.
    private var lastEmitted = ""
    private var currentCandidate = ""
    private var candidateChangedAt = Date()
    private var sequence = 0
    /// The static page chrome (video title, player buttons, sidebar) present at arm — captured from the
    /// FIRST non-empty read and then ignored for the life of the tap, so only text that appears AFTER arm
    /// (an actual subtitle) can become a caption. See ``ScreenTextBaseline``. Reset on every `start`.
    private var baseline: Set<String> = []
    private var baselineCaptured = false

    init(makeReader: @escaping @Sendable (Locale) -> any OnScreenTextReading) {
        self.makeReader = makeReader
    }

    func start(
        plan: CaptionTranscriptionPlan,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        _ = onLevel   // a screen reader never meters audio; the meter rests at 0 (see type doc)
        // OCR reads whatever script is on screen; it cannot translate, so `plan.mode` is moot here and the
        // source locale only tunes the reader. The English-direct route is the Whisper audio leg's job.
        let locale = plan.sourceLocale
        stopped.withLock { $0 = false }

        // Freeze the frontmost window NOW (cursor=nil so the notch/pointer never wins) — the read target
        // for the whole session. Throwing here is fine: the fuser starts the screen source best-effort,
        // so "no readable window" simply means caption rides audio-only.
        let target = try await Self.resolveFrontmostTarget()
        let reader = makeReader(locale)

        queue.sync {
            self.onSegment = onSegment
            self.reader = reader
            self.target = target
            self.lastEmitted = ""
            self.currentCandidate = ""
            self.candidateChangedAt = Date()
            self.sequence = 0
            self.baseline = []
            self.baselineCaptured = false
            self.reading = false
            self.generation += 1
            self.startTicker()
        }

        if stopped.withLock({ $0 }) { tearDownOnQueue() }
    }

    func stop() {
        stopped.withLock { $0 = true }
        queue.async { [weak self] in self?.clearSessionRefs() }
    }

    // MARK: - Teardown

    private func clearSessionRefs() {
        ticker?.cancel(); ticker = nil
        reader = nil
        target = nil
        onSegment = nil
        generation += 1   // drop any read already in flight, even before a re-arm
    }

    private func tearDownOnQueue() {
        queue.sync { self.clearSessionRefs() }
    }

    // MARK: - Poll loop (queue-confined)

    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        ticker = timer
        timer.resume()
    }

    /// One poll: launch the (async) read off-queue, then fold the snapshot back ON the queue. Drops the
    /// tick if a prior read is still in flight, so a slow OCR pass never overlaps itself or queues up.
    private func tick() {
        if stopped.withLock({ $0 }) { return }
        guard !reading, let reader, let target else { return }
        reading = true
        let captured = generation
        Task { [weak self] in
            let snapshot = try? await reader.readText(target: target)
            self?.queue.async { self?.handle(snapshot, generation: captured) }
        }
    }

    /// Fold one read into the segment state on the queue: extract the caption candidate, track how long
    /// it has held, and emit a stable segment once the pure policy says it has settled into a NEW line.
    /// Drops outright when the generation moved (stop / re-arm) so a stale read never touches a fresh
    /// session — checked BEFORE `reading` is cleared so it cannot clobber the new session's latch.
    private func handle(_ snapshot: ScreenTextSnapshot?, generation captured: Int) {
        guard generation == captured else { return }
        reading = false
        if stopped.withLock({ $0 }) { return }

        // Chrome baseline: the first non-empty read is the static page furniture present at arm (title,
        // player buttons, sidebar). Capture it and emit NOTHING from it — only text that appears AFTER
        // arm can be a caption. A static page (e.g. a song with no subtitles) therefore stays silent and
        // the fuser's audio path carries the caption. See ``ScreenTextBaseline``.
        let lines = snapshot?.lines ?? []
        if !baselineCaptured {
            guard !lines.isEmpty else { return }
            baseline = ScreenTextBaseline.signature(of: lines)
            baselineCaptured = true
            return
        }
        let candidate: String
        if let snapshot {
            let kept = ScreenTextBaseline.filtered(snapshot.lines, excluding: baseline)
            let pruned = ScreenTextSnapshot(
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                lines: kept,
                source: snapshot.source
            )
            candidate = OnScreenLineExtractor.caption(from: pruned) ?? ""
        } else {
            candidate = ""
        }
        let now = Date()
        if !ScreenTextSegmentPolicy.isSameLine(candidate, currentCandidate) {
            currentCandidate = candidate
            candidateChangedAt = now
        }
        let decision = ScreenTextSegmentPolicy.decide(
            candidate: currentCandidate,
            lastEmitted: lastEmitted,
            secondsSinceCandidateChanged: now.timeIntervalSince(candidateChangedAt)
        )
        guard decision == .finalize else { return }
        lastEmitted = currentCandidate
        sequence += 1
        let segment = TranscriptSegment(text: currentCandidate, isStable: true, sequence: sequence)
        if stopped.withLock({ $0 }) { return }
        onSegment?(segment)
    }

    // MARK: - Target resolution (device glue)

    /// Resolve the frontmost app's largest window, EXCLUDING our own notch HUD, as the frozen read
    /// target. Reuses the pure ``CaptureTargetSelector`` (cursor=nil, so it never picks the window under
    /// the pointer — the notch — only the frontmost app's surface). Throws when nothing is readable.
    private static func resolveFrontmostTarget() async throws -> ScreenTextTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let descriptors = content.windows.map { window in
            CaptureWindowDescriptor(
                windowID: window.windowID,
                frame: window.frame,
                ownerPID: window.owningApplication?.processID ?? -1,
                layer: window.windowLayer,
                appName: window.owningApplication?.applicationName,
                title: window.title
            )
        }
        guard let chosen = CaptureTargetSelector.selectWindow(
            windows: descriptors,
            cursor: nil,
            ownerPID: ownPID,
            frontmostPID: frontPID
        ) else {
            throw CaptureError.failed("No readable window to caption. Bring the show window to the front, then try again.")
        }
        return ScreenTextTarget(
            windowID: chosen.windowID,
            pid: chosen.ownerPID,
            appName: chosen.appName,
            windowTitle: chosen.title
        )
    }
}

#endif

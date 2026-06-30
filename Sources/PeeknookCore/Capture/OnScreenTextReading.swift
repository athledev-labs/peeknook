// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The caption target window, RESOLVED ONCE at arm and frozen for the life of the tap. Captions read a
/// single chosen surface (the frontmost app's window when the user armed), never "whatever is focused
/// each poll" — so focusing the notch, or another window stealing focus, can't redirect the read. A pure
/// `Sendable` value (window id + owning pid + identity), so it crosses the reader's concurrency boundary
/// and a test can construct one without any window server.
public struct ScreenTextTarget: Sendable, Equatable {
    /// The window-server id of the target window (`CGWindowID`). The OCR reader re-resolves the live
    /// `SCWindow` from this each poll; the accessibility reader matches the owning app by `pid`.
    public let windowID: UInt32
    /// The owning process id, so the accessibility reader can walk the right app's window.
    public let pid: Int32
    public let appName: String?
    public let windowTitle: String?

    public init(windowID: UInt32, pid: Int32, appName: String? = nil, windowTitle: String? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

/// A reader that produces one ``ScreenTextSnapshot`` of the frozen caption target. The narrow seam the
/// screen-text caption source taps each poll — distinct conformers read the SAME window different ways
/// (accessibility structure vs on-device OCR of a screenshot), and a ``CompositeScreenTextReader``
/// arbitrates between them. A NEW reader (e.g. a MusicKit synced-lyric source) is a new conformer here,
/// never a branch in the source.
///
/// Contract: return a snapshot (possibly EMPTY — the window had nothing to read) for an ordinary read;
/// THROW only when the read could not run at all (permission missing, framework unavailable, target
/// gone). On-device only — no reader may reach the network.
public protocol OnScreenTextReading: Sendable {
    func readText(target: ScreenTextTarget) async throws -> ScreenTextSnapshot
}

/// Stand-in for platforms/builds without a usable screen-text backend (so the package compiles
/// everywhere and the source degrades to audio-only). Always throws — there is simply no screen to read.
public struct UnavailableScreenTextReader: OnScreenTextReading {
    public init() {}
    public func readText(target: ScreenTextTarget) async throws -> ScreenTextSnapshot {
        throw CaptureError.failed("Reading on-screen text requires macOS with screen capture available.")
    }
}

#if DEBUG
/// A scriptable screen-text reader for tests and the fuser's stub-driven coverage. Replays a queue of
/// scripted snapshots (last one repeats once exhausted), or throws a scripted error to simulate a reader
/// that cannot run. Records the read count and the last target for assertions.
public final class StubScreenTextReader: OnScreenTextReading, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [ScreenTextSnapshot]
    private var readError: Error?
    private var _readCount = 0
    private var _lastTarget: ScreenTextTarget?

    public init(scripted: [ScreenTextSnapshot] = [], error: Error? = nil) {
        self.scripted = scripted
        self.readError = error
    }

    public var readCount: Int { lock.withLock { _readCount } }
    public var lastTarget: ScreenTextTarget? { lock.withLock { _lastTarget } }

    public func readText(target: ScreenTextTarget) async throws -> ScreenTextSnapshot {
        try lock.withLock {
            _readCount += 1
            _lastTarget = target
            if let readError { throw readError }
            if scripted.isEmpty { return ScreenTextSnapshot.empty(source: .opticalCharacterRecognition) }
            return scripted.count == 1 ? scripted[0] : scripted.removeFirst()
        }
    }
}
#endif

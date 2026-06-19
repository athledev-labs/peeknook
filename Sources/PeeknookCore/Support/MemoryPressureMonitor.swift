// SPDX-License-Identifier: Apache-2.0

import Foundation
import Dispatch

/// Wraps a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source for the **critical** level only and forwards
/// the event to a handler. Peeknook's largest memory cost is the resident vision model; when the
/// system is critically low, the orchestrator uses this to release it (Ollama `keep_alive: 0`) so a
/// capture-triggered overcommit doesn't swap-thrash the whole Mac.
///
/// The handler runs on a private dispatch queue, so it hops to the main actor itself. Start/stop are
/// idempotent; the source is cancelled on `stop()` and on `deinit`.
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.peeknook.memory-pressure", qos: .utility)
    private let onCritical: @Sendable () -> Void
    private var source: DispatchSourceMemoryPressure?

    public init(onCritical: @escaping @Sendable () -> Void) {
        self.onCritical = onCritical
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.source == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: self.queue)
            source.setEventHandler { [weak self] in
                guard let self, self.source?.data.contains(.critical) == true else { return }
                self.onCritical()
            }
            source.resume()
            self.source = source
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    deinit {
        source?.cancel()
    }
}

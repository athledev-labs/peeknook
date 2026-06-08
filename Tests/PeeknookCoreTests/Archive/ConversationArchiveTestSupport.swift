// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
@testable import PeeknookCore

extension Result where Success == Void, Failure == ConversationArchiveError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var archiveFailure: ConversationArchiveError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

enum ConversationArchiveTestSupport {
    static func makeStore(
        directory: URL,
        legacyFileURL: URL? = nil,
        maxThreads: Int = ConversationArchiveStore.defaultMaxThreads,
        maxBytes: Int = ConversationArchiveStore.defaultMaxBytes,
        protection: (any ConversationArchiveProtection)? = nil
    ) -> ConversationArchiveStore {
        ConversationArchiveStore(
            directory: directory,
            legacyFileURL: legacyFileURL,
            maxThreads: maxThreads,
            maxBytes: maxBytes,
            protection: protection ?? FixedKeyArchiveProtection()
        )
    }
}

struct FailingArchiveProtection: ConversationArchiveProtection {
    var error: ArchiveProtectionError = .keyUnavailable

    func seal(_ plaintext: Data) throws -> Data { throw error }
    func open(_ sealed: Data) throws -> Data { throw error }
}

/// Controllable, thread-safe tri-state marker for the fail-closed gate tests. `available == false`
/// models a keychain that can't be reached, so `value()` returns nil (the store must fail soft).
final class SealMarkerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sealed: Bool
    private let available: Bool

    init(sealed: Bool, available: Bool = true) {
        self.sealed = sealed
        self.available = available
    }

    func value() -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return available ? sealed : nil
    }

    func mark() {
        lock.lock(); defer { lock.unlock() }
        if available { sealed = true }
    }
}

/// Test protection that delegates seal/open to a fixed AES key and the sealed-marker methods to a
/// controllable ``SealMarkerBox``, so tests can exercise the fail-closed gate without the Keychain.
struct MarkerArchiveProtection: ConversationArchiveProtection {
    let inner: FixedKeyArchiveProtection
    let box: SealMarkerBox

    init(box: SealMarkerBox, key: SymmetricKey = ConversationArchiveTestSupport.sharedTestKey) {
        self.inner = FixedKeyArchiveProtection(key: key)
        self.box = box
    }

    func seal(_ plaintext: Data) throws -> Data { try inner.seal(plaintext) }
    func open(_ sealed: Data) throws -> Data { try inner.open(sealed) }
    func archiveHasBeenSealed() -> Bool? { box.value() }
    func markArchiveSealed() { box.mark() }
}

extension ConversationArchiveTestSupport {
    /// Deterministic key shared by ``MarkerArchiveProtection`` instances in a test so a fixture this
    /// test seals itself round-trips through the store under test.
    static let sharedTestKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))
}

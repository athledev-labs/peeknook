// SPDX-License-Identifier: Apache-2.0

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

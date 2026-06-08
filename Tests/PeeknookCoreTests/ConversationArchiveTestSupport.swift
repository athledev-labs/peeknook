// SPDX-License-Identifier: Apache-2.0

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

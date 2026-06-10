// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Exercises the credential seam through `InMemoryCredentialStore` — `KeychainCredentialStore`
/// shares the contract but needs a real Keychain (no entitlement under `swift test`), mirroring
/// how `FixedKeyArchiveProtection` stands in for `KeychainArchiveProtection`.
final class CredentialStoreTests: XCTestCase {
    private let ref = CredentialRef.openAICompatiblePrimary

    func testKeylessReturnsNilAndHasKeyFalse() {
        let store = InMemoryCredentialStore()
        XCTAssertNil(store.apiKey(for: ref))
        XCTAssertFalse(store.hasKey(for: ref))
    }

    func testSetThenReadRoundTrips() throws {
        let store = InMemoryCredentialStore()
        try store.setAPIKey("sk-local-test", for: ref)
        XCTAssertEqual(store.apiKey(for: ref), "sk-local-test")
        XCTAssertTrue(store.hasKey(for: ref))
    }

    func testEmptyKeyClears() throws {
        let store = InMemoryCredentialStore()
        try store.setAPIKey("sk-local-test", for: ref)
        try store.setAPIKey("", for: ref)
        XCTAssertNil(store.apiKey(for: ref))
        XCTAssertFalse(store.hasKey(for: ref))
    }

    func testWhitespaceOnlyKeyTreatedAsKeyless() throws {
        let store = InMemoryCredentialStore()
        try store.setAPIKey("   \n", for: ref)
        XCTAssertNil(store.apiKey(for: ref))
        XCTAssertFalse(store.hasKey(for: ref))
    }

    func testStoredKeyIsTrimmed() throws {
        let store = InMemoryCredentialStore()
        try store.setAPIKey("  sk-local-test \n", for: ref)
        XCTAssertEqual(store.apiKey(for: ref), "sk-local-test")
    }

    func testNilKeyClears() throws {
        let store = InMemoryCredentialStore()
        try store.setAPIKey("sk-local-test", for: ref)
        try store.setAPIKey(nil, for: ref)
        XCTAssertNil(store.apiKey(for: ref))
    }

    func testDeleteIsIdempotent() throws {
        let store = InMemoryCredentialStore()
        try store.deleteAPIKey(for: ref)
        try store.setAPIKey("sk-local-test", for: ref)
        try store.deleteAPIKey(for: ref)
        try store.deleteAPIKey(for: ref)
        XCTAssertNil(store.apiKey(for: ref))
    }

    /// The locked-Keychain contract: unreadable degrades to keyless, never throws or blocks.
    func testFailReadsDegradesToKeyless() {
        let store = InMemoryCredentialStore(
            seed: [ref: "sk-local-test"],
            failReads: true
        )
        XCTAssertNil(store.apiKey(for: ref))
        XCTAssertFalse(store.hasKey(for: ref))
    }

    func testDistinctRefsIsolateKeys() throws {
        let store = InMemoryCredentialStore()
        let profileRef = CredentialRef.openAICompatible(profileID: "p1")
        try store.setAPIKey("primary", for: ref)
        try store.setAPIKey("profile", for: profileRef)
        XCTAssertEqual(store.apiKey(for: ref), "primary")
        XCTAssertEqual(store.apiKey(for: profileRef), "profile")
        try store.deleteAPIKey(for: profileRef)
        XCTAssertEqual(store.apiKey(for: ref), "primary")
    }

    /// Ref ids are persisted Keychain account names — changing one orphans the user's stored key.
    func testRefIdsAreStablePersistedFormat() {
        XCTAssertEqual(CredentialRef.openAICompatiblePrimary.id, "openai-compatible-primary")
        XCTAssertEqual(
            CredentialRef.openAICompatible(profileID: "p1").id,
            "openai-compatible-profile-p1"
        )
    }
}

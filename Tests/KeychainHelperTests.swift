import XCTest
import Security

final class KeychainHelperTests: XCTestCase {

    private func makeHelper() -> KeychainHelper {
        KeychainHelper(service: "com.shenanigans.sticky-notes.tests", inMemoryOnly: true)
    }

    func testMultipleKeysRoundTripFromSessionCacheWithoutSecItem() {
        let store = makeHelper()
        XCTAssertTrue(store.save(key: "ms_access_token", string: "tok-a"))
        XCTAssertTrue(store.save(key: "ms_refresh_token", string: "tok-r"))
        XCTAssertTrue(store.save(key: "ms_token_expiry", string: "12345"))
        XCTAssertTrue(store.save(key: "ms_user_email", string: "user@example.com"))
        XCTAssertTrue(store.save(key: "ms_user_name", string: "User"))

        XCTAssertEqual(store.copyMatchingCallCount, 0, "内存会话不得访问钥匙串")
        XCTAssertEqual(store.writeCallCount, 0, "内存会话不得写入钥匙串")

        XCTAssertEqual(store.readString(key: "ms_access_token"), "tok-a")
        XCTAssertEqual(store.readString(key: "ms_refresh_token"), "tok-r")
        XCTAssertEqual(store.readString(key: "ms_token_expiry"), "12345")
        XCTAssertEqual(store.readString(key: "ms_user_email"), "user@example.com")
        XCTAssertEqual(store.readString(key: "ms_user_name"), "User")
        XCTAssertEqual(store.copyMatchingCallCount, 0)
    }

    func testRepeatedReadsDoNotTouchKeychainAfterHydration() {
        let store = makeHelper()
        XCTAssertTrue(store.save(key: "ms_access_token", string: "cached"))
        for _ in 0..<20 {
            XCTAssertEqual(store.readString(key: "ms_access_token"), "cached")
        }
        XCTAssertEqual(store.copyMatchingCallCount, 0)
    }

    func testDeleteRemovesOnlyThatFieldFromSession() {
        let store = makeHelper()
        _ = store.save(key: "ms_access_token", string: "tok-a")
        _ = store.save(key: "ms_refresh_token", string: "tok-r")
        XCTAssertTrue(store.delete(key: "ms_access_token"))
        XCTAssertNil(store.readString(key: "ms_access_token"))
        XCTAssertEqual(store.readString(key: "ms_refresh_token"), "tok-r")
    }

    func testUnifiedHydrationReadsOnceAndDoesNotRewriteOnLaunch() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"], dp: true)
        let store = KeychainHelper(backend: backend)
        for _ in 0..<20 { XCTAssertEqual(store.readString(key: "ms_access_token"), "fake") }
        XCTAssertEqual(backend.reads.count, 1)
        XCTAssertEqual(backend.writes.count, 0)
    }

    func testDeniedHydrationDoesNotFallbackRepromptOrOverwrite() {
        let backend = FakeKeychainBackend()
        backend.readStatus = errSecAuthFailed
        let store = KeychainHelper(backend: backend)
        for _ in 0..<20 { XCTAssertNil(store.readString(key: "ms_access_token")) }
        XCTAssertFalse(store.update(strings: ["ms_access_token": "fake"]))
        XCTAssertEqual(backend.reads.count, 1)
        XCTAssertEqual(backend.writes.count, 0)
    }

    func testConcurrentReadsHydrateOnlyOnce() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"], dp: true)
        let store = KeychainHelper(backend: backend)
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            XCTAssertEqual(store.readString(key: "ms_access_token"), "fake")
        }
        XCTAssertEqual(backend.reads.count, 1)
    }

    func testBatchUpdateUsesOnlyCanonicalBackendOnce() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-old"])
        let store = KeychainHelper(backend: backend)
        XCTAssertTrue(store.update(strings: ["ms_access_token": "fake-new", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "1"]))
        XCTAssertEqual(backend.writes.count, 1)
        XCTAssertFalse(backend.writes[0].1)
    }

    func testClearAllDeletesExactSessionAndLegacyItemsWithoutReadingOrWriting() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"], dp: true)
        backend.seed(["ms_access_token": "fake"])
        let store = KeychainHelper(backend: backend)
        XCTAssertTrue(store.clearAll())
        XCTAssertEqual(backend.reads.count, 0)
        XCTAssertEqual(backend.writes.count, 0)
        XCTAssertEqual(backend.deletes.count, 12)
        XCTAssertTrue(backend.items.isEmpty)
        XCTAssertNil(store.readString(key: "ms_access_token"))
        XCTAssertEqual(backend.reads.count, 0)
    }

    func testLegacyDiscoveryUsesOnlyKnownKeysWithoutInteraction() {
        let backend = FakeKeychainBackend()
        let store = KeychainHelper(backend: backend)
        XCTAssertNil(store.readString(key: "ms_access_token"))
        let legacy = backend.reads.filter { $0.0 != KeychainHelper.sessionAccount }
        XCTAssertEqual(legacy.count, 10)
        XCTAssertTrue(legacy.allSatisfy { !$0.2 && KeychainHelper.legacyAccounts.contains($0.0) })
        XCTAssertEqual(backend.writes.count, 0)
    }

    func testInteractiveReplacementSkipsLegacyDiscoveryAndWritesSingleSession() {
        let backend = FakeKeychainBackend()
        let store = KeychainHelper(backend: backend)
        XCTAssertTrue(store.replaceSession(strings: ["ms_access_token": "fake-new", "ms_graph_account_id": "fake-B"]))
        XCTAssertTrue(backend.reads.allSatisfy { $0.0 == KeychainHelper.sessionAccount })
        XCTAssertEqual(backend.writes.count, 1)
        XCTAssertEqual(store.readString(key: "ms_graph_account_id"), "fake-B")
    }
}

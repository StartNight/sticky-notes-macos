import XCTest
import Security

@MainActor
final class AuthManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        suite = "StickyNotes.AuthTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        MockURLProtocol.reset()
        URLProtocol.registerClass(MockURLProtocol.self)
    }
    override func tearDown() async throws {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suite)
    }
    private func seededStore() -> KeychainHelper {
        let store = KeychainHelper(inMemoryOnly: true)
        store.update(strings: ["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh",
                               "ms_token_expiry": "1", "ms_graph_account_id": "fake-A"])
        return store
    }
    func testAuthorizationURLAlwaysSelectsAccountAndUsesEphemeralSession() throws {
        let auth = AuthManager(keychain: KeychainHelper(inMemoryOnly: true), defaults: defaults, loadStoredAuth: false)
        let url = try auth.authorizationURL(state: "fake-state", challenge: "fake-challenge")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "prompt" }?.value, "select_account")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "fake-state")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertFalse(items.contains { $0.name == "login_hint" })
        XCTAssertTrue(AuthManager.usesEphemeralSession)
    }
    func testSignOutClearsMemoryIdentityAndSurvivesRelaunch() {
        let store = seededStore()
        let auth = AuthManager(keychain: store, defaults: defaults)
        XCTAssertTrue(auth.isAuthenticated)
        let generation = auth.sessionGeneration
        auth.signOut()
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertNil(auth.accountID)
        XCTAssertNotEqual(auth.sessionGeneration, generation)
        XCTAssertNil(store.readString(key: "ms_access_token"))
        XCTAssertNil(store.readString(key: "ms_refresh_token"))
        XCTAssertNil(store.readString(key: "ms_graph_account_id"))
        let reopened = AuthManager(keychain: store, defaults: defaults)
        XCTAssertFalse(reopened.isAuthenticated)
    }
    func testFailedDeletionStillSuppressesAutomaticRestoreWithoutReadingCredentials() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access", "ms_graph_account_id": "fake-A"])
        backend.deleteStatus = errSecAuthFailed
        let store = KeychainHelper(backend: backend)
        let auth = AuthManager(keychain: store, defaults: defaults, loadStoredAuth: false)
        auth.signOut()
        XCTAssertNotNil(auth.lastAuthError)
        let reopened = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        XCTAssertFalse(reopened.isAuthenticated)
        XCTAssertEqual(backend.reads.count, 0)
    }
    func testConcurrentRefreshIsSingleFlightAndBatchPersistsOnce() async throws {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "1", "ms_graph_account_id": "fake-A"], dp: true)
        let store = KeychainHelper(backend: backend)
        let auth = AuthManager(keychain: store, defaults: defaults)
        MockURLProtocol.responseDelay = 0.08
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["access_token": "fake-new", "refresh_token": "fake-refresh-new", "expires_in": 3600]) }
        async let one = auth.refreshTokens()
        async let two = auth.refreshTokens()
        let tokens = try await [one, two]
        XCTAssertEqual(tokens, ["fake-new", "fake-new"])
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(backend.writes.count, 1)
        XCTAssertEqual(backend.reads.count, 1)
    }
    func testLateRefreshCannotRestoreSignedOutSession() async throws {
        let store = seededStore()
        let auth = AuthManager(keychain: store, defaults: defaults)
        MockURLProtocol.responseDelay = 0.15
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["access_token": "fake-late", "expires_in": 3600]) }
        let task = Task { try await auth.refreshTokens() }
        for _ in 0..<100 {
            if !MockURLProtocol.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        auth.signOut()
        do { _ = try await task.value; XCTFail("退出后不得恢复刷新结果") } catch {}
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertNil(auth.accountID)
        XCTAssertNil(store.readString(key: "ms_access_token"))
    }
    func testLegacySessionMustResolveGraphIDBeforeSync() async throws {
        let store = KeychainHelper(inMemoryOnly: true)
        store.update(strings: ["ms_access_token": "fake-access"])
        let auth = AuthManager(keychain: store, defaults: defaults)
        XCTAssertNil(auth.accountID)
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "fake-graph-id"]) }
        let id = try await auth.ensureAccountID()
        XCTAssertEqual(id, "fake-graph-id")
        XCTAssertEqual(auth.accountID, "fake-graph-id")
        XCTAssertEqual(store.readString(key: "ms_graph_account_id"), "fake-graph-id")
    }

    func testRejectedRefreshInvalidatesSessionWithoutDeletingStoredCredentials() async throws {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "1", "ms_graph_account_id": "fake-A"], dp: true)
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        MockURLProtocol.handler = { _ in .http(status: 400, json: [:]) }
        do { _ = try await auth.refreshTokens(); XCTFail("刷新拒绝应抛错") } catch {}
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertNil(auth.accountID)
        XCTAssertTrue(backend.deletes.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: "ms_explicitly_signed_out"))
    }

    func testConcurrentIdentityResolutionReadsProfileAndPersistsOnlyOnce() async throws {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access"], dp: true)
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        MockURLProtocol.responseDelay = 0.05
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "fake-A"]) }
        async let a = auth.ensureAccountID()
        async let b = auth.ensureAccountID()
        let ids = try await [a, b]
        XCTAssertEqual(ids, ["fake-A", "fake-A"])
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(backend.writes.count, 1)
    }
}

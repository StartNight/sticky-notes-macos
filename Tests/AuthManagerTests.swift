import XCTest
import Security
import AuthenticationServices

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
    func testSignOutClearsMemoryIdentityAndSurvivesRelaunch() async {
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
        await auth.waitForKeychainWork()
        let reopened = AuthManager(keychain: store, defaults: defaults)
        XCTAssertFalse(reopened.isAuthenticated)
    }
    func testFailedDeletionStillSuppressesAutomaticRestoreWithoutReadingCredentials() async {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access", "ms_graph_account_id": "fake-A"])
        backend.deleteStatus = errSecAuthFailed
        let store = KeychainHelper(backend: backend)
        let auth = AuthManager(keychain: store, defaults: defaults, loadStoredAuth: false)
        auth.signOut()
        await auth.waitForKeychainWork()
        XCTAssertNotNil(auth.lastAuthError)
        let reopened = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        XCTAssertFalse(reopened.isAuthenticated)
        XCTAssertEqual(backend.reads.count, 0)
    }
    func testConcurrentRefreshIsSingleFlightAndBatchPersistsOnce() async throws {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "1", "ms_graph_account_id": "fake-A"])
        let store = KeychainHelper(backend: backend)
        let auth = AuthManager(keychain: store, defaults: defaults)
        await auth.waitForRestore()
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
        await auth.waitForKeychainWork()
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
        backend.seed(["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "1", "ms_graph_account_id": "fake-A"])
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        MockURLProtocol.handler = { _ in .http(status: 400, json: [:]) }
        do { _ = try await auth.refreshTokens(); XCTFail("刷新拒绝应抛错") } catch {}
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertNil(auth.accountID)
        XCTAssertTrue(backend.deletes.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: "ms_explicitly_signed_out"))
    }

    func testConcurrentIdentityResolutionReadsProfileAndPersistsOnlyOnce() async throws {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access"])
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        MockURLProtocol.responseDelay = 0.05
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "fake-A"]) }
        async let a = auth.ensureAccountID()
        async let b = auth.ensureAccountID()
        let ids = try await [a, b]
        XCTAssertEqual(ids, ["fake-A", "fake-A"])
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(backend.writes.count, 1)
    }

    // MARK: Keychain mitigation (background restore, consent, sign-out scope)

    private func seededBackend() -> FakeKeychainBackend {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "9999999999", "ms_graph_account_id": "fake-A", "ms_user_email": "a@example.test"])
        return backend
    }

    func testRestoreRunsInBackgroundAndIdentityIsUnconfirmedUntilItFinishes() async {
        let backend = seededBackend()
        backend.gate = DispatchSemaphore(value: 0)
        backend.entered = DispatchSemaphore(value: 0)
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        // init returned on the main thread even though the keychain read is hung
        XCTAssertEqual(auth.restoreState, .loading)
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.activeScope, .blocked, "读取未完成：不显示任何账号数据，也不当作未登录")
        backend.gate!.signal()
        await auth.waitForRestore()
        XCTAssertEqual(auth.restoreState, .done)
        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertEqual(auth.activeScope, .account("fake-A"))
        XCTAssertEqual(backend.reads.count, 1)
    }

    func testNeedsInteractionShowsExplanationOnceThenExactlyOneInteractiveRead() async {
        let backend = seededBackend()
        backend.nonInteractiveStatus = -25308
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        XCTAssertEqual(auth.restoreState, .needsConsent)
        XCTAssertTrue(auth.needsKeychainExplanation)
        XCTAssertEqual(auth.activeScope, .blocked)
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(backend.reads.map { $0.2 }, [false], "说明提示前不做交互读取")
        await auth.confirmKeychainAccess()
        XCTAssertEqual(backend.reads.map { $0.2 }, [false, true])
        XCTAssertEqual(auth.restoreState, .done)
        XCTAssertFalse(auth.needsKeychainExplanation)
        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertEqual(auth.accountID, "fake-A")
        await auth.confirmKeychainAccess() // no second prompt
        XCTAssertEqual(backend.reads.count, 2)
    }

    func testNormalSuccessNeverShowsTheExplanation() async {
        let backend = seededBackend()
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        XCTAssertFalse(auth.needsKeychainExplanation)
        XCTAssertEqual(backend.reads.map { $0.2 }, [false])
    }

    func testDecliningTheExplanationReadsNothingAndKeepsEverything() async {
        let backend = seededBackend()
        backend.nonInteractiveStatus = -25308
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        auth.declineKeychainAccess()
        XCTAssertEqual(auth.restoreState, .denied(Int32(errSecUserCanceled)))
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.activeScope, .unlinkedLocal, "未授权：按未登录处理，不显示账号数据")
        await auth.confirmKeychainAccess()
        XCTAssertEqual(backend.reads.count, 1)
        XCTAssertTrue(backend.writes.isEmpty && backend.deletes.isEmpty)
        XCTAssertTrue(backend.hasItem(KeychainHelper.sessionAccount))
        XCTAssertFalse(defaults.bool(forKey: "ms_explicitly_signed_out"))
    }

    func testCancelledInteractiveReadIsNotRetriedAndNothingIsDeletedOrRecreated() async {
        let backend = seededBackend()
        backend.nonInteractiveStatus = -25308
        backend.interactiveStatus = errSecUserCanceled
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        await auth.confirmKeychainAccess()
        XCTAssertEqual(auth.restoreState, .denied(Int32(errSecUserCanceled)))
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertNotNil(auth.lastAuthError)
        XCTAssertTrue(auth.lastAuthError?.contains("-128") == true, "日志/提示含 OSStatus")
        await auth.confirmKeychainAccess()
        auth.beginRestore()
        await auth.waitForRestore()
        XCTAssertEqual(backend.reads.count, 2, "取消后同一次启动不再重试")
        XCTAssertTrue(backend.writes.isEmpty && backend.deletes.isEmpty)
        XCTAssertTrue(backend.hasItem(KeychainHelper.sessionAccount))
    }

    func testSignOutRemovesOnlyTheCurrentSessionAndRelaunchDoesNotAutoSignIn() async {
        let backend = seededBackend()
        for account in KeychainHelper.legacyAccounts { backend.seedRaw(account: account, "legacy-old-\(account)") }
        backend.seedRaw(account: "other-app-item", "unrelated")
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        XCTAssertTrue(auth.isAuthenticated)
        auth.signOut()
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.activeScope, .unlinkedLocal)
        await auth.waitForKeychainWork()
        XCTAssertFalse(backend.hasItem(KeychainHelper.sessionAccount), "当前会话项已从钥匙串移除")
        XCTAssertEqual(backend.deletes.map(\.0), [KeychainHelper.sessionAccount])
        for account in KeychainHelper.legacyAccounts { XCTAssertTrue(backend.hasItem(account)) }
        XCTAssertTrue(backend.hasItem("other-app-item"))
        XCTAssertNil(auth.lastAuthError)
        let readsBefore = backend.reads.count
        let relaunched = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await relaunched.waitForRestore()
        XCTAssertFalse(relaunched.isAuthenticated, "重开不会自动登录（已退出标记）")
        XCTAssertEqual(relaunched.activeScope, .unlinkedLocal)
        XCTAssertEqual(backend.reads.count, readsBefore, "已退出时连钥匙串都不读")
    }

    func testSignOutDuringHungRestoreIsNotRevivedByTheLateResult() async {
        let backend = seededBackend()
        backend.gate = DispatchSemaphore(value: 0)
        backend.entered = DispatchSemaphore(value: 0)
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        auth.signOut()
        backend.gate!.signal()
        await auth.waitForRestore()
        await auth.waitForKeychainWork()
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertNil(auth.accountID)
        XCTAssertEqual(auth.restoreState, .done)
    }
    // MARK: Login cancelled / failed must leave the pre-login state intact (follow-up #1)

    private func callback(from authURL: URL, code: String = "fake-code") -> URL {
        let state = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        return URL(string: "msauth.com.shenanigans.sticky-notes://auth?code=\(code)&state=\(state)")!
    }

    func testCancelledLoginKeepsPreviousSessionAndRelaunchAgreesWithTheUI() async {
        let backend = seededBackend()
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        XCTAssertTrue(auth.isAuthenticated)
        let generation = auth.sessionGeneration
        auth.authSessionRunner = { _, _ in throw NSError(domain: ASWebAuthenticationSessionErrorDomain, code: ASWebAuthenticationSessionError.canceledLogin.rawValue) }
        do { try await auth.signIn(); XCTFail("取消应抛错") } catch {}
        XCTAssertTrue(auth.isAuthenticated, "取消后 UI 必须仍是登录前的状态")
        XCTAssertEqual(auth.accountID, "fake-A")
        XCTAssertEqual(auth.userEmail, "a@example.test")
        XCTAssertFalse(auth.isAuthenticating)
        XCTAssertEqual(auth.activeScope, .account("fake-A"))
        XCTAssertNotEqual(auth.sessionGeneration, generation, "登录开始时作废的旧同步范围不得复活")
        XCTAssertTrue(backend.hasItem(KeychainHelper.sessionAccount))
        XCTAssertTrue(backend.deletes.isEmpty && backend.writes.isEmpty, "取消不写也不删钥匙串")
        XCTAssertFalse(defaults.bool(forKey: "ms_explicitly_signed_out"))
        // 重启后的状态与取消后 UI 一致（都是仍登录原账号）
        let relaunched = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await relaunched.waitForRestore()
        XCTAssertEqual(relaunched.isAuthenticated, auth.isAuthenticated)
        XCTAssertEqual(relaunched.accountID, auth.accountID)
    }

    func testCancelledLoginWhenSignedOutStaysSignedOut() async {
        let auth = AuthManager(keychain: KeychainHelper(inMemoryOnly: true), defaults: defaults, loadStoredAuth: false)
        auth.authSessionRunner = { _, _ in throw CancellationError() }
        do { try await auth.signIn(); XCTFail() } catch {}
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.activeScope, .unlinkedLocal)
    }

    func testFailedTokenExchangeAlsoRestoresPreviousSessionAndStoresNothingNew() async {
        let backend = seededBackend()
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        auth.authSessionRunner = { [self] url, _ in callback(from: url) }
        MockURLProtocol.handler = { _ in .http(status: 400, json: ["error": "invalid_grant"]) }
        do { try await auth.signIn(); XCTFail() } catch {}
        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertEqual(auth.accountID, "fake-A")
        XCTAssertTrue(backend.writes.isEmpty && backend.deletes.isEmpty)
    }

    func testSignOutDuringLoginIsNeverUndoneByTheCancelRestore() async {
        let backend = seededBackend()
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        auth.authSessionRunner = { _, _ in
            auth.signOut()                       // user signs out while the sheet is up
            throw CancellationError()
        }
        do { try await auth.signIn(); XCTFail() } catch {}
        await auth.waitForKeychainWork()
        XCTAssertFalse(auth.isAuthenticated, "显式退出优先，取消不得把旧会话恢复回来")
        XCTAssertNil(auth.accountID)
        XCTAssertTrue(defaults.bool(forKey: "ms_explicitly_signed_out"))
        XCTAssertFalse(backend.hasItem(KeychainHelper.sessionAccount))
    }

    func testSuccessfulLoginReplacesTheSessionAndDoesNotRestoreTheOldOne() async throws {
        let backend = seededBackend()
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        auth.authSessionRunner = { [self] url, _ in callback(from: url) }
        MockURLProtocol.handler = { request in
            if request.url?.host == "login.microsoftonline.com" {
                return .http(status: 200, json: ["access_token": "fake-new", "refresh_token": "fake-refresh-new", "expires_in": 3600])
            }
            return .http(status: 200, json: ["id": "fake-B", "displayName": "B", "mail": "b@example.test"])
        }
        try await auth.signIn()
        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertEqual(auth.accountID, "fake-B")
        XCTAssertEqual(auth.userEmail, "b@example.test")
    }
}

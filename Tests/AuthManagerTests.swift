import XCTest
import Security
import AuthenticationServices
import SwiftData

final class FakeClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

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
        let auth = AuthManager(keychain: store, defaults: defaults, verifyIdentityAfterRestore: false)
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
        let reopened = AuthManager(keychain: store, defaults: defaults, verifyIdentityAfterRestore: false)
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
        let reopened = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
        XCTAssertFalse(reopened.isAuthenticated)
        XCTAssertEqual(backend.reads.count, 0)
    }
    func testConcurrentRefreshIsSingleFlightAndBatchPersistsOnce() async throws {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "1", "ms_graph_account_id": "fake-A"])
        let store = KeychainHelper(backend: backend)
        let auth = AuthManager(keychain: store, defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: store, defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: store, defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
        await auth.waitForRestore()
        XCTAssertFalse(auth.needsKeychainExplanation)
        XCTAssertEqual(backend.reads.map { $0.2 }, [false])
    }

    func testDecliningTheExplanationReadsNothingAndKeepsEverything() async {
        let backend = seededBackend()
        backend.nonInteractiveStatus = -25308
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let relaunched = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
        await relaunched.waitForRestore()
        XCTAssertFalse(relaunched.isAuthenticated, "重开不会自动登录（已退出标记）")
        XCTAssertEqual(relaunched.activeScope, .unlinkedLocal)
        XCTAssertEqual(backend.reads.count, readsBefore, "已退出时连钥匙串都不读")
    }

    func testSignOutDuringHungRestoreIsNotRevivedByTheLateResult() async {
        let backend = seededBackend()
        backend.gate = DispatchSemaphore(value: 0)
        backend.entered = DispatchSemaphore(value: 0)
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let relaunched = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults, verifyIdentityAfterRestore: false)
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
    // MARK: Startup identity re-verification (follow-up #3)

    private func verifiedBackend() -> FakeKeychainBackend {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "9999999999",
                      "ms_graph_account_id": "fake-A", "ms_user_email": "a@example.test", "ms_user_name": "A"])
        return backend
    }
    nonisolated private func graphMe(_ id: String) -> MockURLProtocol.Reply {
        .http(status: 200, json: ["id": id, "displayName": "A", "mail": "a@example.test"])
    }

    func testStartupCachedAccountIsProvisionalUntilMeConfirmsItWithoutKeychainWrites() async {
        let backend = verifiedBackend()
        MockURLProtocol.responseDelay = 0.05
        MockURLProtocol.handler = { [self] _ in graphMe("fake-A") }
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        XCTAssertFalse(auth.isIdentityVerified, "缓存账号 ID 在复核前不能当作已确认身份")
        XCTAssertEqual(auth.activeScope, .account("fake-A"), "复核前仅本地显示缓存账号（不放行云端操作）")
        await auth.waitForIdentityVerification()
        XCTAssertTrue(auth.isIdentityVerified)
        XCTAssertEqual(auth.accountID, "fake-A")
        XCTAssertEqual(MockURLProtocol.requests.map(\.url.path), ["/v1.0/me"])
        XCTAssertTrue(backend.writes.isEmpty, "值未变化时不写钥匙串（避免重建后弹窗）")
    }

    func testStartupMismatchBlocksScopeKeepsKeychainAndNeverAdoptsTheOtherAccount() async {
        let backend = verifiedBackend()
        MockURLProtocol.responseDelay = 0.05
        MockURLProtocol.handler = { [self] _ in graphMe("fake-B") }
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        await auth.waitForIdentityVerification()
        XCTAssertNil(auth.accountID)
        XCTAssertFalse(auth.isIdentityVerified)
        XCTAssertEqual(auth.activeScope, .blocked, "不一致 → 身份未确认 → 不展示任何内容")
        XCTAssertNil(auth.userEmail)
        XCTAssertNotNil(auth.lastAuthError)
        XCTAssertTrue(backend.writes.isEmpty && backend.deletes.isEmpty, "不改写、不删除钥匙串")
        XCTAssertTrue(backend.hasItem(KeychainHelper.sessionAccount))
        do { _ = try await auth.ensureAccountID(); XCTFail("不一致时不得悄悄改认 B") } catch {}
        XCTAssertEqual(MockURLProtocol.requests.count, 1, "不一致状态下不重复请求，也不静默换号")
        // 重新登录后恢复正常（标记被清除）
        auth.signOut()
        await auth.waitForKeychainWork()
        XCTAssertEqual(auth.activeScope, .unlinkedLocal)
    }

    func testUnreachableGraphKeepsIdentityProvisionalAndLaterRetryConfirms() async throws {
        let backend = verifiedBackend()
        MockURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        let auth = AuthManager(keychain: KeychainHelper(backend: backend), defaults: defaults)
        await auth.waitForRestore()
        await auth.waitForIdentityVerification()
        XCTAssertEqual(auth.accountID, "fake-A")
        XCTAssertFalse(auth.isIdentityVerified, "无法联网复核：保持未确认，禁止云端读写")
        XCTAssertEqual(auth.activeScope, .account("fake-A"))
        MockURLProtocol.handler = { [self] _ in graphMe("fake-A") }
        let id = try await auth.ensureAccountID()
        XCTAssertEqual(id, "fake-A")
        XCTAssertTrue(auth.isIdentityVerified)
    }

    func testSignInSuccessMarksNewIdentityVerified() async throws {
        let auth = AuthManager(keychain: KeychainHelper(inMemoryOnly: true), defaults: defaults, loadStoredAuth: false)
        auth.authSessionRunner = { [self] url, _ in callback(from: url) }
        MockURLProtocol.handler = { request in
            if request.url?.host == "login.microsoftonline.com" {
                return .http(status: 200, json: ["access_token": "fake-new", "refresh_token": "fake-refresh-new", "expires_in": 3600])
            }
            return .http(status: 200, json: ["id": "fake-C", "displayName": "C", "mail": "c@example.test"])
        }
        try await auth.signIn()
        XCTAssertTrue(auth.isIdentityVerified)
        XCTAssertEqual(auth.activeScope, .account("fake-C"))
    }
    // MARK: Token refresh: sequential coalescing + backoff (follow-up #6)

    private func expiredStore() -> FakeKeychainBackend {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "1",
                      "ms_graph_account_id": "fake-A", "ms_user_email": "a@example.test", "ms_user_name": "A"])
        return backend
    }
    private func tokenReply(expires: Double = 3600) -> MockURLProtocol.Reply {
        .http(status: 200, json: ["access_token": "fake-new", "refresh_token": "fake-refresh-new", "expires_in": expires])
    }

    func testSequentialRefreshRequestsWithinCooldownShareOneNetworkCall() async throws {
        let clock = FakeClock()
        let auth = AuthManager(keychain: KeychainHelper(backend: expiredStore()), defaults: defaults,
                               verifyIdentityAfterRestore: false, now: { clock.date })
        await auth.waitForRestore()
        MockURLProtocol.handler = { [self] _ in tokenReply() }
        let first = try await auth.refreshTokens()
        // e.g. the next note's PATCH also returned 403 a second later in the same sync pass
        clock.advance(2)
        let second = try await auth.refreshTokens()
        clock.advance(3)
        let third = try await auth.refreshTokens()
        XCTAssertEqual([first, second, third], ["fake-new", "fake-new", "fake-new"])
        XCTAssertEqual(MockURLProtocol.requests.count, 1, "冷却期内的连续刷新只发一次网络请求")
        XCTAssertEqual(auth.refreshNetworkCallCount, 1)
        clock.advance(61)
        _ = try await auth.refreshTokens()
        XCTAssertEqual(MockURLProtocol.requests.count, 2, "冷却期过后仍能真正刷新")
    }

    func testShortLivedTokenDoesNotCauseARefreshOnEveryAccess() async throws {
        let clock = FakeClock()
        let auth = AuthManager(keychain: KeychainHelper(backend: expiredStore()), defaults: defaults,
                               verifyIdentityAfterRestore: false, now: { clock.date })
        await auth.waitForRestore()
        MockURLProtocol.handler = { [self] _ in tokenReply(expires: 120) }   // inside the 5-minute early-refresh window
        for _ in 0..<5 { _ = try await auth.getValidAccessToken(); clock.advance(1) }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testFailedRefreshBacksOffExponentiallyAndRecovers() async throws {
        let clock = FakeClock()
        let auth = AuthManager(keychain: KeychainHelper(backend: expiredStore()), defaults: defaults,
                               verifyIdentityAfterRestore: false, now: { clock.date })
        await auth.waitForRestore()
        MockURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        func attempt(expecting code: Int? = nil, line: UInt = #line) async {
            do { _ = try await auth.refreshTokens(); XCTFail("应失败", line: line) }
            catch { if let code { XCTAssertEqual((error as NSError).code, code, line: line) } }
        }
        await attempt(); XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertTrue(auth.isAuthenticated, "网络失败不等于登出")
        await attempt(expecting: -16); XCTAssertEqual(MockURLProtocol.requests.count, 1)
        clock.advance(31)                                              // 30s base elapsed
        await attempt(); XCTAssertEqual(MockURLProtocol.requests.count, 2)
        clock.advance(31)                                              // second failure doubles to 60s
        await attempt(expecting: -16); XCTAssertEqual(MockURLProtocol.requests.count, 2)
        clock.advance(30)
        await attempt(); XCTAssertEqual(MockURLProtocol.requests.count, 3)
        // 恢复：成功后清除退避，并进入冷却合并
        MockURLProtocol.handler = { [self] _ in tokenReply() }
        clock.advance(121)
        let token = try await auth.refreshTokens()
        XCTAssertEqual(token, "fake-new"); XCTAssertEqual(MockURLProtocol.requests.count, 4)
        let again = try await auth.refreshTokens()
        XCTAssertEqual(again, "fake-new"); XCTAssertEqual(MockURLProtocol.requests.count, 4)
    }

    func testBackoffIsCappedAndRejectedTokenStillSignsOutImmediately() async throws {
        let clock = FakeClock()
        let auth = AuthManager(keychain: KeychainHelper(backend: expiredStore()), defaults: defaults,
                               verifyIdentityAfterRestore: false, now: { clock.date })
        await auth.waitForRestore()
        MockURLProtocol.handler = { _ in .failure(.timedOut) }
        for _ in 0..<12 { _ = try? await auth.refreshTokens(); clock.advance(1000) }
        let before = MockURLProtocol.requests.count
        clock.advance(AuthManager.refreshBackoffCap + 1)
        _ = try? await auth.refreshTokens()
        XCTAssertEqual(MockURLProtocol.requests.count, before + 1, "退避上限 \(AuthManager.refreshBackoffCap)s，超过后一定会重试")
        MockURLProtocol.handler = { _ in .http(status: 400, json: [:]) }
        clock.advance(2000)
        _ = try? await auth.refreshTokens()
        XCTAssertFalse(auth.isAuthenticated, "令牌被拒绝仍立即失效（不受退避影响）")
    }

    // 真实 AuthManager + SyncEngine：一次同步里多条便笺各自 403（缺 ShortNotes）曾各触发一次令牌刷新。
    private func perNote403Storm(cooldown: TimeInterval) async throws -> (tokenCalls: Int, uploaded: Int) {
        let store = KeychainHelper(inMemoryOnly: true)
        store.update(strings: ["ms_access_token": "fake-access", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "9999999999",
                               "ms_graph_account_id": "acct-A", "ms_user_email": "a@example.test", "ms_user_name": "A"])
        let auth = AuthManager(keychain: store, defaults: defaults, verifyIdentityAfterRestore: false, refreshCooldown: cooldown)
        await auth.waitForRestore()
        let schema = Schema([StickyNote.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        var notes: [StickyNote] = []
        for i in 1...3 {
            let n = StickyNote(content: "note \(i)", remoteId: "R\(i)", ownerAccountID: "acct-A", changeKey: "ck\(i)")
            n.syncStatus = .pendingUpload
            context.insert(n); notes.append(n)
        }
        try context.save()
        let created = Counter()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.url?.host == "login.microsoftonline.com" {
                return .http(status: 200, json: ["access_token": "fake-new-\(UUID().uuidString.prefix(4))", "expires_in": 3600])
            }
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/v1.0/me"): return .http(status: 200, json: ["id": "acct-A", "displayName": "A", "mail": "a@example.test"])
            case ("GET", _): return .http(status: 200, json: ["value": []])
            case ("PATCH", _): return .http(status: 403, json: ["error": "forbidden"])
            case ("POST", _):
                let n = created.next()
                return .http(status: 201, json: ["id": "new-\(n)", "changeKey": "ckn\(n)", "body": ["contentType": "html", "content": "x"]])
            default: return .http(status: 204, json: nil)
            }
        }
        _ = try await auth.ensureAccountID()
        let engine = SyncEngine(authManager: auth, debounceNanoseconds: 1_000_000)
        await engine.syncAll(modelContext: context)
        let tokenCalls = MockURLProtocol.requests.filter { $0.url.host == "login.microsoftonline.com" }.count
        return (tokenCalls, notes.filter { $0.remoteId?.hasPrefix("new-") == true }.count)
    }
    final class Counter { private var n = 0; func next() -> Int { n += 1; return n } }

    func testWithoutCooldownEveryNote403TriggersItsOwnRefresh_RootCauseOfTheBurst() async throws {
        let result = try await perNote403Storm(cooldown: 0)
        XCTAssertEqual(result.uploaded, 3)
        XCTAssertGreaterThanOrEqual(result.tokenCalls, 3, "根因复现：每条便笺的 403 各自触发一次刷新")
    }

    func testPerNote403StormNowRefreshesOnlyOnce() async throws {
        let result = try await perNote403Storm(cooldown: 60)
        XCTAssertEqual(result.uploaded, 3, "同步行为不变：三条仍走回退创建并成功")
        XCTAssertEqual(result.tokenCalls, 1, "冷却内合并为一次刷新")
    }
}

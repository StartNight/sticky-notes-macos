import XCTest
import Security

/// Mock backend only: nothing here touches the real Keychain, real items or credentials.
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
        XCTAssertEqual(store.readString(key: "ms_user_name"), "User")
        XCTAssertEqual(store.copyMatchingCallCount, 0)
    }

    func testRepeatedReadsDoNotTouchKeychainAfterHydration() {
        let store = makeHelper()
        XCTAssertTrue(store.save(key: "ms_access_token", string: "cached"))
        for _ in 0..<20 { XCTAssertEqual(store.readString(key: "ms_access_token"), "cached") }
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

    func testStatusClassification() {
        XCTAssertEqual(KeychainProbe.classify(errSecSuccess), .success)
        XCTAssertEqual(KeychainProbe.classify(errSecItemNotFound), .notFound)
        XCTAssertEqual(KeychainProbe.classify(-25308), .needsInteraction)
        XCTAssertEqual(KeychainProbe.classify(errSecInteractionRequired), .needsInteraction)
        XCTAssertEqual(KeychainProbe.classify(errSecUserCanceled), .denied(errSecUserCanceled))
        XCTAssertEqual(KeychainProbe.classify(-128), .denied(-128))
        XCTAssertEqual(KeychainProbe.classify(errSecAuthFailed), .denied(errSecAuthFailed))
        XCTAssertEqual(KeychainProbe.classify(-9999), .failed(-9999))
    }

    func testUnhydratedReadsNeverTouchTheBackendAndReturnNil() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"])
        let store = KeychainHelper(backend: backend)
        XCTAssertNil(store.readString(key: "ms_access_token"), "未读取完成前读取接口只返回缓存，不做钥匙串 I/O")
        XCTAssertFalse(store.isHydrated)
        XCTAssertEqual(backend.reads.count, 0)
        XCTAssertFalse(store.update(strings: ["ms_access_token": "overwrite-attempt"]), "未读取不得覆盖已有会话")
        XCTAssertEqual(backend.writes.count, 0)
    }

    func testNonInteractiveProbeReadsOnceAndDoesNotRewriteOnLaunch() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"])
        let store = KeychainHelper(backend: backend)
        XCTAssertEqual(store.probeNonInteractive(), .success)
        for _ in 0..<20 { XCTAssertEqual(store.readString(key: "ms_access_token"), "fake") }
        XCTAssertEqual(backend.reads.count, 1)
        XCTAssertFalse(backend.reads[0].2, "启动探测必须非交互")
        XCTAssertFalse(backend.reads[0].1, "不再探测数据保护钥匙串")
        XCTAssertEqual(backend.writes.count, 0)
    }

    func testNeedsInteractionIsReportedThenExactlyOneInteractiveReadIsAllowed() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"])
        backend.nonInteractiveStatus = -25308
        let store = KeychainHelper(backend: backend)
        XCTAssertEqual(store.probeNonInteractive(), .needsInteraction)
        XCTAssertEqual(store.loadState, .needsConsent)
        XCTAssertFalse(store.isHydrated)
        XCTAssertNil(store.readString(key: "ms_access_token"))
        XCTAssertEqual(store.readInteractive(), .success)
        XCTAssertEqual(store.readString(key: "ms_access_token"), "fake")
        XCTAssertEqual(backend.reads.map { $0.2 }, [false, true])
        XCTAssertEqual(store.readInteractive(), .success)
        XCTAssertEqual(backend.reads.count, 2, "同一次启动只允许一次交互读取")
        XCTAssertTrue(backend.deletes.isEmpty); XCTAssertTrue(backend.writes.isEmpty)
    }

    func testUserCancelOnInteractiveReadIsFinalForThisLaunchWithoutDeleteOrRecreate() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"])
        backend.nonInteractiveStatus = -25308
        backend.interactiveStatus = errSecUserCanceled
        let store = KeychainHelper(backend: backend)
        XCTAssertEqual(store.probeNonInteractive(), .needsInteraction)
        XCTAssertEqual(store.readInteractive(), .denied(errSecUserCanceled))
        XCTAssertEqual(store.loadState, .denied(errSecUserCanceled))
        let readsAfterCancel = backend.reads.count
        XCTAssertEqual(store.readInteractive(), .denied(errSecUserCanceled))
        XCTAssertEqual(store.probeNonInteractive(), .denied(errSecUserCanceled))
        XCTAssertEqual(backend.reads.count, readsAfterCancel, "取消后同一次启动不再重试")
        XCTAssertFalse(store.update(strings: ["ms_access_token": "x"]))
        XCTAssertFalse(store.save(key: "k", string: "v"))
        XCTAssertTrue(backend.writes.isEmpty && backend.deletes.isEmpty, "不自动删除/重建旧项")
        XCTAssertTrue(backend.hasItem(KeychainHelper.sessionAccount))
    }

    func testDeniedNonInteractiveProbeDoesNotFallbackRepromptOrOverwrite() {
        let backend = FakeKeychainBackend()
        backend.readStatus = errSecAuthFailed
        let store = KeychainHelper(backend: backend)
        XCTAssertEqual(store.hydrateBlocking(), .denied(errSecAuthFailed))
        for _ in 0..<20 { XCTAssertNil(store.readString(key: "ms_access_token")) }
        XCTAssertFalse(store.update(strings: ["ms_access_token": "fake"]))
        XCTAssertEqual(store.hydrateBlocking(), .denied(errSecAuthFailed))
        XCTAssertEqual(backend.reads.count, 1)
        XCTAssertEqual(backend.writes.count, 0)
    }

    func testDeclineNeverReadsAtAll() {
        let backend = FakeKeychainBackend()
        backend.nonInteractiveStatus = -25308
        let store = KeychainHelper(backend: backend)
        _ = store.probeNonInteractive()
        store.declineInteractiveRead()
        _ = store.readInteractive()
        XCTAssertEqual(backend.reads.count, 1)
        XCTAssertEqual(store.loadState, .denied(errSecUserCanceled))
    }

    func testConcurrentProbesHitTheBackendOnlyOnce() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"])
        let store = KeychainHelper(backend: backend)
        DispatchQueue.concurrentPerform(iterations: 40) { _ in _ = store.probeNonInteractive() }
        XCTAssertEqual(backend.reads.count, 1)
        XCTAssertEqual(store.readString(key: "ms_access_token"), "fake")
    }

    func testBatchUpdateUsesOnlyCanonicalBackendOnce() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-old"])
        let store = KeychainHelper(backend: backend)
        store.hydrateBlocking()
        XCTAssertTrue(store.update(strings: ["ms_access_token": "fake-new", "ms_refresh_token": "fake-refresh", "ms_token_expiry": "1"]))
        XCTAssertEqual(backend.writes.count, 1)
        XCTAssertFalse(backend.writes[0].1)
    }

    func testClearAllDeletesOnlyTheCurrentSessionItemAndLeavesLegacyAndUnrelatedItems() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"])
        for account in KeychainHelper.legacyAccounts { backend.seedRaw(account: account, "legacy-\(account)") }
        backend.seedRaw(account: "someone-elses-item", "unrelated")
        let store = KeychainHelper(backend: backend)
        XCTAssertTrue(store.clearAll())
        XCTAssertEqual(backend.reads.count, 0)
        XCTAssertEqual(backend.writes.count, 0)
        XCTAssertEqual(backend.deletes.map(\.0), [KeychainHelper.sessionAccount], "只删当前会话项")
        XCTAssertFalse(backend.hasItem(KeychainHelper.sessionAccount))
        for account in KeychainHelper.legacyAccounts { XCTAssertTrue(backend.hasItem(account), "旧项保留：\(account)") }
        XCTAssertTrue(backend.hasItem("someone-elses-item"))
        XCTAssertNil(store.readString(key: "ms_access_token"))
    }

    func testLegacyCleanupIsExplicitAndRemovesOnlyTheFiveKnownAccounts() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"])
        for account in KeychainHelper.legacyAccounts { backend.seedRaw(account: account, "legacy") }
        backend.seedRaw(account: "unrelated", "x")
        let store = KeychainHelper(backend: backend)
        XCTAssertTrue(store.clearLegacyItems())
        XCTAssertEqual(Set(backend.deletes.map(\.0)), Set(KeychainHelper.legacyAccounts))
        XCTAssertTrue(backend.hasItem(KeychainHelper.sessionAccount))
        XCTAssertTrue(backend.hasItem("unrelated"))
    }

    func testClearAllReportsFailureWithoutPretendingSuccess() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"])
        backend.deleteStatus = errSecAuthFailed
        let store = KeychainHelper(backend: backend)
        XCTAssertFalse(store.clearAll())
        XCTAssertNil(store.readString(key: "ms_access_token"), "内存会话仍立即失效")
    }

    func testLegacyDiscoveryUsesOnlyKnownKeysWithoutInteractionAndWithoutDataProtectionProbe() {
        let backend = FakeKeychainBackend()
        let store = KeychainHelper(backend: backend)
        XCTAssertEqual(store.probeNonInteractive(), .notFound)
        let legacy = backend.reads.filter { $0.0 != KeychainHelper.sessionAccount }
        XCTAssertEqual(legacy.count, 5)
        XCTAssertTrue(legacy.allSatisfy { !$0.2 && !$0.1 && KeychainHelper.legacyAccounts.contains($0.0) })
        XCTAssertEqual(backend.writes.count, 0)
        XCTAssertTrue(backend.reads.allSatisfy { !$0.1 }, "没有任何 DP 探测")
    }

    func testLegacyMigrationWritesSessionButNeverDeletesLegacyItems() {
        let backend = FakeKeychainBackend()
        backend.seedRaw(account: "ms_access_token", "legacy-token")
        let store = KeychainHelper(backend: backend)
        XCTAssertEqual(store.probeNonInteractive(), .success)
        XCTAssertEqual(store.readString(key: "ms_access_token"), "legacy-token")
        XCTAssertEqual(backend.writes.count, 1)
        XCTAssertTrue(backend.deletes.isEmpty)
        XCTAssertTrue(backend.hasItem("ms_access_token"))
    }

    func testInteractiveReplacementDoesNotReadOldItemAndWritesSingleSession() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake-old"])
        let store = KeychainHelper(backend: backend)
        XCTAssertTrue(store.replaceSession(strings: ["ms_access_token": "fake-new", "ms_graph_account_id": "fake-B"]))
        XCTAssertEqual(backend.reads.count, 0)
        XCTAssertEqual(backend.writes.count, 1)
        XCTAssertEqual(store.readString(key: "ms_graph_account_id"), "fake-B")
    }

    func testQueuedWriteBeforeSignOutIsVoidedByTheEpoch() {
        let backend = FakeKeychainBackend()
        let store = KeychainHelper(backend: backend)
        XCTAssertTrue(store.replaceSession(strings: ["ms_access_token": "a"]))
        let epoch = store.currentEpoch
        store.discardCache()
        XCTAssertFalse(store.update(strings: ["ms_access_token": "late"], requiredEpoch: epoch))
        XCTAssertFalse(store.replaceSession(strings: ["ms_access_token": "late"], requiredEpoch: epoch))
        XCTAssertEqual(backend.writes.count, 1)
        XCTAssertNil(store.readString(key: "ms_access_token"))
    }

    @MainActor
    func testMainThreadNeverWaitsOnAHungKeychainRead() async throws {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "fake"])
        backend.gate = DispatchSemaphore(value: 0)
        backend.entered = DispatchSemaphore(value: 0)
        let store = KeychainHelper(backend: backend)
        let probe = Task { await store.probeNonInteractiveAsync() }
        // Wait (off the main thread) until the backend is actually blocked inside the "prompt".
        let reachedBackend = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: backend.entered!.wait(timeout: .now() + 5) == .success) }
        }
        XCTAssertTrue(reachedBackend)
        // While the read is hung, everything the UI thread uses returns immediately.
        let start = Date()
        XCTAssertNil(store.readString(key: "ms_access_token"))
        XCTAssertFalse(store.isHydrated)
        XCTAssertEqual(store.loadState, .idle)
        XCTAssertEqual(store.currentEpoch, 0)
        store.discardCache()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "主线程不得等待钥匙串")
        backend.gate!.signal()
        _ = await probe.value
    }

    // MARK: Phase 2 Regression Tests (C-04, C-05)

    func testFailedReplaceSessionFromDeniedStateDoesNotCorruptStateFlags() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "old"])
        let store = KeychainHelper(backend: backend)
        store.declineInteractiveRead()
        XCTAssertEqual(store.loadState, .denied(errSecUserCanceled))

        backend.writeStatus = errSecAuthFailed
        XCTAssertFalse(store.replaceSession(strings: ["ms_access_token": "new"]))
        XCTAssertEqual(store.loadState, .denied(errSecUserCanceled), "replaceSession 写入失败不得破坏原 loadState")
        XCTAssertNil(store.readString(key: "ms_access_token"))
    }

    func testEpochGuardedClearAllDoesNotDeleteNewerSession() {
        let backend = FakeKeychainBackend()
        backend.seed(["ms_access_token": "old"])
        let store = KeychainHelper(backend: backend)
        let oldEpoch = store.discardCache()
        // New session bumps epoch via replaceSession after a newer discard or sign-in:
        let newEpoch = store.discardCache()
        XCTAssertNotEqual(oldEpoch, newEpoch)
        XCTAssertTrue(store.replaceSession(strings: ["ms_access_token": "fresh"], requiredEpoch: newEpoch))
        XCTAssertTrue(store.clearAll(requiredEpoch: oldEpoch))
        XCTAssertTrue(backend.hasItem(KeychainHelper.sessionAccount), "过期 epoch 的 clearAll 不得删除新会话")
        XCTAssertEqual(store.readString(key: "ms_access_token"), "fresh")
    }
}

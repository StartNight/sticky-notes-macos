import XCTest
import SwiftData
import AppKit

/// Deterministic network barriers; entirely temporary stores + auth mock + MockURLProtocol.
@MainActor
final class SyncLifecycleTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var engine: SyncEngine!
    private var suiteName: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        MockURLProtocol.reset()
        URLProtocol.registerClass(MockURLProtocol.self)
        SyncAuthStub.shared.reset()
        let schema = Schema([StickyNote.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        suiteName = "sync-lifecycle-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        engine = SyncEngine(authManager: SyncAuthStub.shared, debounceNanoseconds: 1_000_000,
                            colorLedger: ColorEditLedger(defaults: defaults), defaults: defaults, startPeriodicSync: false)
        engine.lastSyncDate = nil
    }
    override func tearDown() async throws {
        engine?.cancelPendingWork()
        // Every held test request must be explicitly completed, not leaked into another test.
        XCTAssertEqual(MockURLProtocol.heldCount, 0)
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        if let suiteName { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        container = nil; engine = nil; defaults = nil; suiteName = nil
    }
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("未到达预定网络/互斥断点", file: file, line: line)
        throw CancellationError()
    }
    private func note(_ text: String = "v1", remote: String? = nil) -> StickyNote {
        let note = StickyNote(content: text, remoteId: remote, ownerAccountID: "test-account", changeKey: remote == nil ? nil : "old")
        context.insert(note)
        return note
    }
    nonisolated private func remote(_ id: String, _ body: String = "cloud") -> [String: Any] {
        ["id": id, "changeKey": "cloud-key", "body": ["content": "<div>\(body)</div>"], "lastModifiedDateTime": "2030-01-01T00:00:00Z"]
    }
    private func assertError(_ engine: SyncEngine, file: StaticString = #filePath, line: UInt = #line) {
        if case .error = engine.state {} else { XCTFail("未完成操作不能显示已同步", file: file, line: line) }
    }

    // R1
    func testErrorStateConflictPreservesTextRichTextColorAndAudio() async throws {
        let local = note("failed-local", remote: "existing")
        local.syncStatus = .error
        local.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        local.noteColor = .purple
        let rich = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "failed-local"), requiringSecureCoding: true)
        local.attributedContentData = rich
        local.audioRecordings = [Data([1, 2, 3])]
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" { return .http(status: 200, json: ["value": [self.remote("existing")]]) }
            return .http(status: 201, json: ["id": "conflict-copy", "changeKey": "copy-key"])
        }
        await engine.syncAll(modelContext: context)
        let notes = try context.fetch(FetchDescriptor<StickyNote>())
        let copy = try XCTUnwrap(notes.first { $0.plainTextContent == "failed-local" })
        XCTAssertEqual(copy.attributedContentData, rich)
        XCTAssertEqual(copy.audioRecordings, [Data([1, 2, 3])])
        XCTAssertEqual(copy.noteColor, .purple)
        XCTAssertEqual(local.plainTextContent, "cloud")
        XCTAssertEqual(notes.count, 2)
    }

    // R2: full sync + delayed single upload share the same per-note lock.
    func testFullSyncAndUploadCreateOnlyOneRemoteObject() async throws {
        let local = note()
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { req in
            req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 201, json: ["id": "one", "changeKey": "key"])
        }
        let first = Task { try await self.engine.uploadNote(local, token: "fake") }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        let second = Task { await self.engine.syncAll(modelContext: self.context) }
        try await waitUntil { self.engine.uploadWaiterCount(for: local.id) == 1 }
        MockURLProtocol.releaseNext()
        try await first.value
        await second.value
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "POST" }.count, 1)
        XCTAssertEqual(local.remoteId, "one")
        XCTAssertEqual(local.syncStatus, .synced)
    }

    func testFullSyncAndDebounceSerializeSameNewNote() async throws {
        let local = note()
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { req in
            req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 201, json: ["id": "one", "changeKey": "key"])
        }
        let full = Task { await self.engine.syncAll(modelContext: self.context) }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        engine.scheduleDebouncedPush(for: local.id, in: context)
        try await waitUntil { self.engine.uploadWaiterCount(for: local.id) == 1 }
        MockURLProtocol.releaseNext()
        await full.value
        try await waitUntil { self.engine.uploadWaiterCount(for: local.id) == 0 }
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "POST" }.count, 1)
    }

    func testOverlappingFullSyncDoesNotStartAnotherPullOrPost() async throws {
        let local = note()
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { req in
            req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 201, json: ["id": "one", "changeKey": "key"])
        }
        let first = Task { await self.engine.syncAll(modelContext: self.context) }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        await engine.syncAll(modelContext: context)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        MockURLProtocol.releaseNext(); await first.value
        XCTAssertEqual(local.remoteId, "one")
    }

    func testOlderUploadResponseDoesNotMarkNewerTextAndColorSynced() async throws {
        let local = note()
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "one", "changeKey": "v1-key"]) }
        let first = Task { try await self.engine.uploadNote(local, token: "fake") }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        local.plainTextContent = "v2"
        local.noteColor = .blue
        local.modifiedAt = Date().addingTimeInterval(1)
        MockURLProtocol.releaseNext(); try await first.value
        XCTAssertEqual(local.remoteId, "one")
        XCTAssertEqual(local.plainTextContent, "v2")
        XCTAssertEqual(local.noteColor, .blue)
        XCTAssertEqual(local.syncStatus, .pendingUpload)
        let json = try XCTUnwrap(local.webNoteJSON?.data(using: .utf8))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["color"] as? Int, 0, "缓存应记录已发送的v1黄，不是未发送的v2蓝")
        MockURLProtocol.holdMethods = []
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "one", "changeKey": "v2-key", "body": ["content": "<div>v2</div>"]]) }
        try await engine.uploadNote(local, token: "fake")
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["POST", "PATCH"])
        XCTAssertEqual(local.syncStatus, .synced)
    }

    // R3: simulate SERVER accepted 201, but active login changed before the response.
    func testAcceptedPostThenAccountSwitchBlocksRecreateAfterReturnAndReload() async throws {
        let local = note("uncertain-local")
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "server-created", "changeKey": "key"]) }
        let first = Task { try await self.engine.uploadNote(local, token: "fake-A") }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        let op = try XCTUnwrap(local.pendingCreateOperationID)
        SyncAuthStub.shared.accountID = "B"; SyncAuthStub.shared.sessionGeneration = UUID()
        MockURLProtocol.releaseNext()
        do { try await first.value; XCTFail("旧代次不应继续") } catch {}
        let reloadedContext = ModelContext(container)
        let reloaded = try XCTUnwrap(reloadedContext.fetch(FetchDescriptor<StickyNote>()).first)
        XCTAssertEqual(reloaded.pendingCreateOperationID, op)
        XCTAssertNil(reloaded.remoteId)
        SyncAuthStub.shared.accountID = "test-account"; SyncAuthStub.shared.sessionGeneration = UUID()
        MockURLProtocol.holdMethods = []
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["value": [self.remote("server-created", "uncertain-local")]]) }
        let restarted = SyncEngine(authManager: SyncAuthStub.shared,
                                   colorLedger: ColorEditLedger(defaults: defaults), defaults: defaults, startPeriodicSync: false)
        defer { restarted.cancelPendingWork() }
        await restarted.syncAll(modelContext: reloadedContext)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "POST" }.count, 1, "不能把client-request-id误当服务端幂等保证")
        XCTAssertEqual(reloaded.plainTextContent, "uncertain-local")
        XCTAssertEqual(reloaded.pendingCreateOperationID, op)
        assertError(restarted)
    }

    func testTimedOutCreatePersistsIntentAndDoesNotBlindlyRetry() async throws {
        let local = note()
        MockURLProtocol.handler = { _ in .failure(.timedOut) }
        do { try await engine.uploadNote(local, token: "fake"); XCTFail() } catch {}
        XCTAssertNotNil(local.pendingCreateOperationID)
        let reloaded = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<StickyNote>()).first)
        let restarted = SyncEngine(authManager: SyncAuthStub.shared,
                                   colorLedger: ColorEditLedger(defaults: defaults), defaults: defaults, startPeriodicSync: false)
        defer { restarted.cancelPendingWork() }
        do { try await restarted.uploadNote(reloaded, token: "fake"); XCTFail() } catch {
            XCTAssertEqual((error as NSError).code, -30)
        }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    // R4
    func testDeletingQueuedDebounceCancelsAllUploads() async throws {
        let local = note(remote: "known")
        engine.scheduleDebouncedPush(for: local.id, in: context)
        try engine.prepareForDeletion(local, modelContext: context)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        do { try await engine.uploadNote(local, token: "fake"); XCTFail() } catch {
            XCTAssertEqual((error as NSError).code, -32)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testDeletedInFlightPatch404CannotFallbackRecreate() async throws {
        let local = note(remote: "known")
        MockURLProtocol.holdMethods = ["PATCH"]
        MockURLProtocol.handler = { _ in .http(status: 404, json: [:]) }
        let upload = Task { try await self.engine.uploadNote(local, token: "fake") }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        try engine.prepareForDeletion(local, modelContext: context)
        MockURLProtocol.releaseNext()
        do { try await upload.value; XCTFail() } catch {}
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["PATCH"])
        XCTAssertTrue(local.isDeletedLocally)
    }

    func testDeletingAcceptedInFlightCreatePreservesIDForDeleteNotResurrection() async throws {
        let local = note()
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "accepted", "changeKey": "key"]) }
        let upload = Task { try await self.engine.uploadNote(local, token: "fake") }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        try engine.prepareForDeletion(local, modelContext: context)
        XCTAssertTrue(local.requiresRemoteCleanup)
        MockURLProtocol.releaseNext(); try await upload.value
        XCTAssertTrue(local.isDeletedLocally)
        XCTAssertEqual(local.remoteId, "accepted")
        XCTAssertNil(local.pendingCreateOperationID)
        MockURLProtocol.holdMethods = []
        MockURLProtocol.handler = { req in req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 204, json: nil) }
        await engine.syncAll(modelContext: context)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "DELETE" }.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StickyNote>()), 0)
    }

    func testDeletedUncertainCreateRemainsDurableBlockedTombstone() async throws {
        let local = note()
        local.pendingCreateOperationID = "fake-uncertain-operation"
        try engine.prepareForDeletion(local, modelContext: context)
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["value": []]) }
        await engine.syncAll(modelContext: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StickyNote>()), 1)
        XCTAssertEqual(local.pendingCreateOperationID, "fake-uncertain-operation")
        assertError(engine)
        XCTAssertNil(engine.lastSyncDate)
    }

    // R5
    func testDeleteFailureCannotReportSyncedOrAdvanceTimestamp() async throws {
        let local = note(remote: "delete-me")
        try engine.prepareForDeletion(local, modelContext: context)
        MockURLProtocol.handler = { req in req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 500, json: [:]) }
        await engine.syncAll(modelContext: context)
        assertError(engine)
        XCTAssertNil(engine.lastSyncDate)
        XCTAssertEqual(local.remoteId, "delete-me")
        XCTAssertTrue(local.isDeletedLocally)
    }

    func testReplacementCleanupSurvivesEngineRestartAndDoesNotRecreateAgain() async throws {
        let local = note(remote: "old-object")
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "PATCH": return .http(status: 403, json: [:])
            case "POST": return .http(status: 201, json: ["id": "new-object", "changeKey": "new-key"])
            default: return .http(status: 500, json: [:])
            }
        }
        do { try await engine.uploadNote(local, token: "fake", retryAuthOnFailure: false); XCTFail("旧对象删除失败应上报") } catch {}
        XCTAssertEqual(local.remoteId, "new-object")
        XCTAssertEqual(local.pendingCleanupRemoteIDs, ["old-object"])
        let newContext = ModelContext(container)
        let restored = try XCTUnwrap(newContext.fetch(FetchDescriptor<StickyNote>()).first)
        XCTAssertEqual(restored.pendingCleanupRemoteIDs, ["old-object"])
        MockURLProtocol.reset()
        MockURLProtocol.handler = { req in req.httpMethod == "GET" ? .http(status: 200, json: ["value": [self.remote("old-object")]]) : .http(status: 204, json: nil) }
        let restarted = SyncEngine(authManager: SyncAuthStub.shared,
                                   colorLedger: ColorEditLedger(defaults: defaults), defaults: defaults, startPeriodicSync: false)
        defer { restarted.cancelPendingWork() }
        await restarted.syncAll(modelContext: newContext)
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET", "DELETE"])
        XCTAssertTrue(restored.pendingCleanupRemoteIDs.isEmpty)
        XCTAssertEqual(try newContext.fetchCount(FetchDescriptor<StickyNote>()), 1)
        XCTAssertEqual(restarted.state, .idle)
    }

    func testCorruptCleanupJournalFailsClosedInsteadOfDroppingOldIDs() async throws {
        let local = note(remote: "known")
        local.pendingCleanupIDsData = Data("not-valid-json".utf8)
        XCTAssertTrue(local.hasCorruptSyncJournal)
        do { try await engine.uploadNote(local, token: "fake"); XCTFail() } catch {
            XCTAssertEqual((error as NSError).code, -36)
        }
        await engine.syncAll(modelContext: context)
        assertError(engine)
        // Per-record isolation: pull may run, but the damaged record is never uploaded/deleted/overwritten.
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.method == "GET" })
        XCTAssertEqual(local.pendingCleanupIDsData, Data("not-valid-json".utf8))
    }

    func testDetachedNoteCannotPostBeforeDurableWriteAheadRecord() async throws {
        let local = StickyNote(content: "not-persisted", ownerAccountID: "test-account")
        do { try await engine.uploadNote(local, token: "fake"); XCTFail() } catch {
            XCTAssertEqual((error as NSError).code, -33)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    // MARK: Phase 2 Regression Tests (C-06, H-05, H-06, H-07, H-08, H-09, H-11)

    func testOfflineCreateClearsPendingIntentAndUploadsWhenBackOnline() async throws {
        let local = note("offline-note")
        MockURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        do { try await engine.uploadNote(local, token: "fake"); XCTFail("Expected offline error") } catch {}
        XCTAssertNil(local.pendingCreateOperationID, "断网前失败不应把新便笺锁死在恢复队列")
        XCTAssertEqual(local.syncStatus, .error)

        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "online-created", "changeKey": "ck1"]) }
        try await engine.uploadNote(local, token: "fake")
        XCTAssertEqual(local.remoteId, "online-created")
        XCTAssertEqual(local.syncStatus, .synced)
    }

    func testDeletingNoteWithHistoricalRecoveryAuditDoesNotDeadlockSync() async throws {
        let local = note("was-recovered", remote: "R-HIST")
        local.syncStatus = .synced
        local.recoveryAudit = [RecoveryAuditEntry(accountID: "test-account", action: "associate-user-attested-exact-object",
                                                  reason: "verified", priorOperationID: nil, remoteID: "R-HIST", kind: .graphNote, changeKey: "ck")]
        try context.save()
        XCTAssertTrue(local.hasRecoveryHistory)
        XCTAssertFalse(local.hasUnresolvedRecoveryState)

        try engine.prepareForDeletion(local, modelContext: context)
        MockURLProtocol.handler = { req in
            req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 204, json: nil)
        }
        await engine.syncAll(modelContext: context)
        XCTAssertEqual(engine.state, .idle, "删除仅有历史审计的便笺后同步应正常恢复 idle")
        XCTAssertNotNil(engine.lastSyncDate)
        XCTAssertNil(local.remoteId)
        XCTAssertTrue(local.recoveryPaused)
    }

    func testRequestDeletionBlocksImmediateDeleteWhenPendingCreateExists() async throws {
        let local = note("uncertain-replace", remote: "R-OLD")
        local.pendingCreateOperationID = "op-in-flight"
        try context.save()
        MockURLProtocol.handler = { _ in .http(status: 204, json: nil) }
        try engine.requestDeletion(of: local, in: context)
        try await Task.sleep(nanoseconds: 25_000_000)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty, "存在未决创建时不得立即发云端 DELETE")
        XCTAssertTrue(local.isDeletedLocally)
        XCTAssertEqual(local.remoteId, "R-OLD")
    }

    func testPullInFlightDoesNotDeleteNoteCreatedConcurrently() async throws {
        let local = note("just-created")
        MockURLProtocol.holdMethods = ["GET"]
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" { return .http(status: 200, json: ["value": []]) }
            return .http(status: 201, json: ["id": "R-NEW", "changeKey": "ck-new"])
        }
        let pullTask = Task { await self.engine.syncAll(modelContext: self.context) }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        // Upload finishes BEFORE the held GET returns; GET's seenRemoteIDs does NOT contain R-NEW.
        try await engine.uploadNote(local, token: "fake")
        XCTAssertEqual(local.remoteId, "R-NEW")
        XCTAssertEqual(local.syncStatus, .synced)
        MockURLProtocol.releaseNext()
        await pullTask.value
        let remaining = try context.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(remaining.count, 1, "旧 GET 快照绝不能误删并发刚上传成功的新便笺")
        XCTAssertEqual(remaining.first?.remoteId, "R-NEW")
    }

    func testCloudDeletionPreservesLocalAudioRecordingsAndMissingChangeKeyDoesNotDelete() async throws {
        let audioNote = note("with-voice", remote: "R-AUDIO")
        audioNote.syncStatus = .synced
        audioNote.audioRecordings = [Data([0xAA, 0xBB])]
        let noChangeKeyNote = note("missing-ck", remote: "R-NOCK")
        noChangeKeyNote.syncStatus = .synced
        try context.save()

        MockURLProtocol.handler = { _ in
            // R-AUDIO absent (deleted in cloud), R-NOCK present but missing changeKey
            .http(status: 200, json: ["value": [["id": "R-NOCK", "body": ["content": "<div>missing-ck</div>"]]]])
        }
        await engine.syncAll(modelContext: context)
        XCTAssertFalse(audioNote.isDeleted, "含本地录音的便笺被云端删除时应脱钩保留而非销毁")
        XCTAssertNil(audioNote.remoteId)
        XCTAssertEqual(audioNote.audioRecordings, [Data([0xAA, 0xBB])])
        XCTAssertTrue(audioNote.recoveryPaused)

        XCTAssertFalse(noChangeKeyNote.isDeleted, "云端条目缺失 changeKey 时不得当作已删除")
        XCTAssertEqual(noChangeKeyNote.remoteId, "R-NOCK")
    }

    func testCorruptJournalSettersNeverOverwriteRawCorruptBytes() throws {
        let local = note("corrupt", remote: "R-1")
        let rawSync = Data("bad-sync-json".utf8)
        let rawAudit = Data("bad-audit-json".utf8)
        local.pendingCleanupIDsData = rawSync
        local.recoveryAuditData = rawAudit
        XCTAssertTrue(local.hasCorruptSyncJournal)
        XCTAssertTrue(local.hasCorruptRecoveryJournal)
        local.pendingCleanupRemoteIDs.append("x")
        local.recoveryAudit.append(RecoveryAuditEntry(accountID: "a", action: "t", reason: "r", priorOperationID: nil, remoteID: nil, kind: nil, changeKey: nil))
        XCTAssertEqual(local.pendingCleanupIDsData, rawSync, "损坏同步日志不得被 setter 静默覆盖")
        XCTAssertEqual(local.recoveryAuditData, rawAudit, "损坏恢复日志不得被 setter 静默覆盖")
    }

    // MARK: Duplicate-Upload & Spurious-Conflict Regression Tests

    func testCloudNewerSameTextDoesNotCreateDuplicateUpload() async throws {
        let local = note("hello world \n", remote: "R-SAME")
        local.syncStatus = .error
        local.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        local.noteColor = .blue
        local.attributedContentData = try NSKeyedArchiver.archivedData(
            withRootObject: NSAttributedString(string: "hello world \n"),
            requiringSecureCoding: true
        )
        local.audioRecordings = [Data([1, 2, 3])]
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [[
                    "id": "R-SAME",
                    "changeKey": "ck-newer",
                    "body": ["content": "<div>hello&nbsp;world</div>"],
                    "lastModifiedDateTime": "2030-01-01T00:00:00Z"
                ]]])
            }
            return .http(status: 500, json: [:])
        }

        await engine.syncAll(modelContext: context)

        let notes = try context.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "POST" }.count, 0, "等效文本的云端新版本不得制造重复副本并二次上传")
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(local.syncStatus, .synced)
        XCTAssertEqual(local.changeKey, "ck-newer")
        XCTAssertEqual(local.audioRecordings, [Data([1, 2, 3])], "收敛时必须保留本地录音")
        XCTAssertEqual(engine.state, .idle)
    }

    func testLocalNewerWhitespaceDifferenceDoesNotCreateDuplicateCloudCopy() async throws {
        let local = note("line 1  \n  line 2\n", remote: "R-WS")
        local.modifiedAt = Date(timeIntervalSince1970: 1_900_000_000)
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "GET":
                return .http(status: 200, json: ["value": [[
                    "id": "R-WS",
                    "changeKey": "ck-server",
                    "body": ["content": "<div>line 1<br/>line 2</div>"],
                    "lastModifiedDateTime": "2025-01-01T00:00:00Z"
                ]]])
            case "PATCH":
                return .http(status: 200, json: [
                    "id": "R-WS",
                    "changeKey": "ck-patched",
                    "body": ["content": "<div>line 1  <br/>  line 2<br/></div>"]
                ])
            default:
                return .http(status: 500, json: [:])
            }
        }

        await engine.syncAll(modelContext: context)

        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "POST" }.count, 0, "首尾空白或换行差异不得产生重复 cloudCopy")
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "PATCH" }.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StickyNote>()), 1)
        XCTAssertEqual(local.syncStatus, .synced)
        XCTAssertEqual(local.changeKey, "ck-patched")
        XCTAssertEqual(engine.state, .idle)
    }

    func testSubstrateChangeKeyBumpAfterSyncDoesNotDuplicateOnSubsequentLocalEdit() async throws {
        let local = note("v1")
        MockURLProtocol.handler = { _ in
            .http(status: 201, json: ["id": "R-1", "changeKey": "ck1", "body": ["content": "<div>v1</div>"]])
        }
        try await engine.uploadNote(local, token: "fake")
        XCTAssertEqual(local.remoteId, "R-1")
        XCTAssertEqual(local.syncStatus, .synced)

        // Local edits to v2; meanwhile server bumps changeKey & timestamp without changing v1 body.
        local.plainTextContent = "v2"
        local.modifiedAt = Date(timeIntervalSince1970: 1_750_000_000)
        local.syncStatus = .pendingUpload
        MockURLProtocol.reset()
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "GET":
                return .http(status: 200, json: ["value": [[
                    "id": "R-1",
                    "changeKey": "ck-bumped",
                    "body": ["content": "<div>v1</div>"],
                    "lastModifiedDateTime": "2030-01-01T00:00:00Z"
                ]]])
            case "PATCH":
                return .http(status: 200, json: ["id": "R-1", "changeKey": "ck2", "body": ["content": "<div>v2</div>"]])
            default:
                return .http(status: 500, json: [:])
            }
        }

        await engine.syncAll(modelContext: context)

        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "POST" }.count, 0, "云端仍为上次已同步基线正文 v1，仅 changeKey 变化时不得复制上传")
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "PATCH" }.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StickyNote>()), 1)
        XCTAssertEqual(local.plainTextContent, "v2")
        XCTAssertEqual(local.syncStatus, .synced)
        XCTAssertEqual(local.changeKey, "ck2")

        // Phase 2: genuine concurrent 3-way divergence (base was v2, local has v3-local, cloud has v3-cloud) must still preserve both.
        local.plainTextContent = "v3-local"
        local.modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        local.syncStatus = .pendingUpload
        MockURLProtocol.reset()
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [[
                    "id": "R-1",
                    "changeKey": "ck3",
                    "body": ["content": "<div>v3-cloud</div>"],
                    "lastModifiedDateTime": "2031-01-01T00:00:00Z"
                ]]])
            }
            return .http(status: 201, json: ["id": "R-COPY", "changeKey": "ck-copy"])
        }

        await engine.syncAll(modelContext: context)

        let notes = try context.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(notes.count, 2, "真正的双向并发分歧编辑仍必须保留双端副本")
        XCTAssertTrue(notes.contains { $0.plainTextContent == "v3-local" })
        XCTAssertTrue(notes.contains { $0.plainTextContent == "v3-cloud" })
    }

    func testPatchBodyVerificationToleratesExchangeWhitespaceNormalization() async throws {
        let local = note("a  b\n", remote: "R-NORM")
        MockURLProtocol.handler = { _ in
            .http(status: 200, json: [
                "id": "R-NORM",
                "changeKey": "ck-2",
                "body": ["content": "<div>a&nbsp;b</div>"]
            ])
        }

        try await engine.uploadNote(local, token: "fake")

        XCTAssertEqual(local.syncStatus, .synced)
        XCTAssertEqual(local.changeKey, "ck-2")
    }

    func testConcurrentPullDuringReplaceRemoteNoteDoesNotDuplicateNewObject() async throws {
        let local = note("edited", remote: "R-OLD")
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "PATCH":
                return .http(status: 403, json: [:])
            case "GET" where req.url?.path.contains("mailFolders") == true:
                return .http(status: 200, json: ["value": [self.remote("R-NEW", "edited")]])
            case "GET":
                return .http(status: 200, json: ["id": "R-OLD", "singleValueExtendedProperties": []])
            case "POST":
                return .http(status: 201, json: ["id": "R-NEW", "changeKey": "ck-new", "body": ["content": "<div>edited</div>"]])
            case "DELETE":
                return .http(status: 204, json: nil)
            default:
                return .http(status: 500, json: [:])
            }
        }

        let uploadTask = Task { try await self.engine.uploadNote(local, token: "fake", retryAuthOnFailure: false) }
        try await waitUntil { MockURLProtocol.heldCount == 1 }

        let pullTask = Task { await self.engine.syncAll(modelContext: self.context) }
        try await waitUntil { self.engine.uploadWaiterCount(for: local.id) == 1 }

        MockURLProtocol.releaseNext()
        try await uploadTask.value
        await pullTask.value

        let notes = try context.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(notes.count, 1, "replaceRemoteNote 在途 POST 期间并发 pull 不得留下重复便笺")
        XCTAssertEqual(local.remoteId, "R-NEW")
        XCTAssertEqual(local.syncStatus, .synced)
    }

    func testConcurrentPullDoesNotResurrectOldObjectDeletedByReplaceRemoteNote() async throws {
        let local = note("edited", remote: "R-OLD")
        MockURLProtocol.holdPredicate = { req in
            req.httpMethod == "GET" && req.url?.path.contains("mailFolders") == true
        }
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "GET" where req.url?.path.contains("mailFolders") == true:
                return .http(status: 200, json: ["value": [self.remote("R-OLD", "before-edit")]])
            case "GET":
                return .http(status: 200, json: ["id": "R-OLD", "singleValueExtendedProperties": []])
            case "PATCH":
                return .http(status: 403, json: [:])
            case "POST":
                return .http(status: 201, json: ["id": "R-NEW", "changeKey": "ck-new", "body": ["content": "<div>edited</div>"]])
            case "DELETE":
                return .http(status: 204, json: nil)
            default:
                return .http(status: 500, json: [:])
            }
        }

        let pullTask = Task { await self.engine.syncAll(modelContext: self.context) }
        try await waitUntil { MockURLProtocol.heldCount == 1 }

        try await engine.uploadNote(local, token: "fake", retryAuthOnFailure: false)
        XCTAssertEqual(local.remoteId, "R-NEW")

        MockURLProtocol.releaseNext()
        await pullTask.value

        let notes = try context.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(notes.count, 1, "旧 GET 快照不得复活已被 replaceRemoteNote 删除的旧对象 R-OLD")
        XCTAssertEqual(local.remoteId, "R-NEW")
        XCTAssertEqual(local.syncStatus, .synced)
        XCTAssertEqual(engine.state, .idle)
    }

    func testPullDeduplicatesRepeatedRemoteIDAcrossPages() async throws {
        let page2URL = "https://graph.microsoft.com/v1.0/me/mailFolders/notes/messages?$skiptoken=p2"
        MockURLProtocol.handler = { req in
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.contains("skiptoken=p2") {
                return .http(status: 200, json: ["value": [self.remote("R-DUP", "hello")]])
            }
            return .http(status: 200, json: [
                "value": [self.remote("R-DUP", "hello")],
                "@odata.nextLink": page2URL
            ])
        }

        await engine.syncAll(modelContext: context)

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StickyNote>()), 1, "跨页重复出现的同一 remoteId 只能保留一条记录")
    }
}

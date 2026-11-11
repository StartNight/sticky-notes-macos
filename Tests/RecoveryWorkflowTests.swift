import XCTest
import SwiftData
import AppKit

@MainActor
final class RecoveryWorkflowTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var engine: SyncEngine!
    private let evidence = "fake test: exact original account / exact object manually reviewed"
    override func setUp() async throws {
        MockURLProtocol.reset(); URLProtocol.registerClass(MockURLProtocol.self)
        SyncAuthStub.shared.reset()
        let schema = Schema([StickyNote.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        engine = SyncEngine(authManager: SyncAuthStub.shared, debounceNanoseconds: 1_000_000)
        engine.lastSyncDate = nil
    }
    override func tearDown() async throws {
        XCTAssertEqual(MockURLProtocol.heldCount, 0)
        MockURLProtocol.reset(); URLProtocol.unregisterClass(MockURLProtocol.self)
        container = nil; engine = nil
    }
    private func source(deleted: Bool = false) -> StickyNote {
        let n = StickyNote(color: .purple, content: "local-newer", ownerAccountID: "test-account")
        n.pendingCreateOperationID = "fake-old-operation"
        n.pendingCreateEndpoint = "/v1.0/me/notes"
        n.pendingCreateStartedAt = Date(timeIntervalSince1970: 123456)
        n.isDeletedLocally = deleted
        context.insert(n)
        return n
    }
    nonisolated private func cloud(id: String = "candidate", key: String = "key", mailClass: String? = nil) -> [String: Any] {
        var obj: [String: Any] = ["id": id, "changeKey": key, "body": ["content": "<div>cloud-older</div>"]]
        if let mailClass { obj["singleValueExtendedProperties"] = [["id": "String 0x001A", "value": mailClass]] }
        return obj
    }
    private func serveCandidate() {
        MockURLProtocol.handler = { request in
            if request.url!.path == "/v1.0/me" { return .http(status: 200, json: ["id": "test-account"]) }
            return .http(status: 200, json: self.cloud())
        }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("未到达指定网络/任务断点"); throw CancellationError()
    }
    private func verify(_ n: StickyNote) async throws -> VerifiedRecoveryCandidate {
        try await engine.verifyRecoveryCandidate(n, id: "candidate", kind: .graphNote)
    }
    private func assertProblem() {
        if case .error = engine.state {} else { XCTFail("问题记录仍未完成，不能显示Synced") }
        XCTAssertGreaterThan(engine.incompleteTaskCount, 0)
    }

    func testOriginalAccountListIncludesHiddenTombstonesAndExcludesOtherAccounts() throws {
        let hidden = source(deleted: true)
        let foreign = source(); foreign.ownerAccountID = "B"
        let records = engine.recoveryRecords(from: [hidden, foreign])
        XCTAssertEqual(records.map(\.id), [hidden.id])
        SyncAuthStub.shared.accountID = "B"
        XCTAssertEqual(engine.recoveryRecords(from: [hidden, foreign]).map(\.id), [foreign.id])
        SyncAuthStub.shared.isAuthenticated = false
        XCTAssertTrue(engine.recoveryRecords(from: [hidden, foreign]).isEmpty)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testExplicitExportContainsRetainedRichTextAudioAndRawJournalButNoNetwork() throws {
        let n = source(deleted: true)
        n.attributedContentData = Data([1, 2, 3]); n.audioRecordings = [Data([4, 5])]
        n.webNoteJSON = "raw-document"
        n.recoveryAuditData = Data("unparseable-but-preserved".utf8)
        let data = try engine.exportRecoveryContent(n)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["plainText"] as? String, "local-newer")
        XCTAssertEqual(json["attributedContentData"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(json["audioRecordings"] as? [String], [Data([4, 5]).base64EncodedString()])
        XCTAssertEqual(json["operationID"] as? String, "fake-old-operation")
        XCTAssertEqual(json["rawRecoveryAuditBase64"] as? String, n.recoveryAuditData?.base64EncodedString())
        XCTAssertNil(json["access_token"]); XCTAssertNil(json["refresh_token"])
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testFreshProfileMismatchRejectsBeforeReadingCandidate() async throws {
        let n = source()
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "B"]) }
        do { _ = try await verify(n); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -44) }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
    }

    func testMailboxCandidateRejectsOrdinaryMailWithoutStickyNoteClass() async throws {
        let n = source()
        MockURLProtocol.handler = { request in
            request.url!.path == "/v1.0/me" ? .http(status: 200, json: ["id": "test-account"]) : .http(status: 200, json: self.cloud(mailClass: "IPM.Note"))
        }
        do { _ = try await engine.verifyRecoveryCandidate(n, id: "candidate", kind: .mailNote); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -45) }
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.method == "GET" })
    }

    func testMailboxCandidateAcceptsExactIDAndStickyNoteClassOnlyRead() async throws {
        let n = source()
        MockURLProtocol.handler = { request in
            request.url!.path == "/v1.0/me" ? .http(status: 200, json: ["id": "test-account"]) : .http(status: 200, json: self.cloud(mailClass: "IPM.StickyNote"))
        }
        let candidate = try await engine.verifyRecoveryCandidate(n, id: "candidate", kind: .mailNote)
        XCTAssertTrue(candidate.exists)
        XCTAssertEqual(candidate.kind, .mailNote)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testNotFoundIsNotProofOfNonCreationAndCannotClearIntent() async throws {
        let n = source()
        MockURLProtocol.handler = { request in
            request.url!.path == "/v1.0/me" ? .http(status: 200, json: ["id": "test-account"]) : .http(status: 404, json: [:])
        }
        do { _ = try await verify(n); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -45) }
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
        XCTAssertTrue(n.recoveryAudit.isEmpty)
    }

    func testAssociationKeepsContentAndArchivesPulledDuplicateWithoutCloudWrites() async throws {
        let n = source(deleted: true)
        n.attributedContentData = Data([1, 2]); n.audioRecordings = [Data([3, 4])]; n.webNoteJSON = "old-raw-json"
        let duplicate = StickyNote(content: "duplicate-with-local-edits", remoteId: "candidate", ownerAccountID: "test-account", syncStatus: .pendingUpload)
        context.insert(duplicate)
        serveCandidate(); let verified = try await verify(n)
        try await engine.confirmRecoveryCandidate(n, candidate: verified, action: .associate, reason: evidence, acknowledged: true)
        XCTAssertEqual(n.remoteId, "candidate"); XCTAssertNil(n.pendingCreateOperationID)
        XCTAssertEqual(n.plainTextContent, "local-newer")
        XCTAssertEqual(n.attributedContentData, Data([1, 2])); XCTAssertEqual(n.audioRecordings, [Data([3, 4])])
        XCTAssertFalse(n.isDeletedLocally); XCTAssertFalse(n.recoveryPaused)
        XCTAssertTrue(n.recoveryBlocksAutomaticRecreate)
        XCTAssertEqual(n.syncStatus, .pendingUpload)
        XCTAssertNil(duplicate.remoteId); XCTAssertTrue(duplicate.recoveryPaused)
        XCTAssertEqual(duplicate.plainTextContent, "duplicate-with-local-edits")
        let all = try context.fetch(FetchDescriptor<StickyNote>())
        XCTAssertTrue(all.contains { $0.recoveryIsArchive && $0.webNoteJSON == "old-raw-json" })
        XCTAssertEqual(n.recoveryAudit.first?.priorOperationID, "fake-old-operation")
        XCTAssertEqual(n.recoveryAudit.first?.priorEndpoint, "/v1.0/me/notes")
        XCTAssertEqual(n.recoveryAudit.first?.priorStartedAt, Date(timeIntervalSince1970: 123456))
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.method == "GET" })
    }

    func testAssociationNeverAutoRecreatesOrDeletesWhenLinkedPatchFails() async throws {
        let n = source(); serveCandidate()
        let candidate = try await verify(n)
        try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .associate, reason: evidence, acknowledged: true)
        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in .http(status: 403, json: [:]) }
        do { try await engine.uploadNote(n, token: "fake", retryAuthOnFailure: false); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -42) }
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["PATCH"])
        XCTAssertEqual(n.remoteId, "candidate")
    }

    func testChangedCandidateVersionRequiresNewReviewAndPerformsNoWrite() async throws {
        let n = source(); serveCandidate(); let candidate = try await verify(n)
        MockURLProtocol.handler = { request in
            request.url!.path == "/v1.0/me" ? .http(status: 200, json: ["id": "test-account"]) : .http(status: 200, json: self.cloud(key: "changed"))
        }
        do { try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .deleteCandidate, reason: evidence, acknowledged: true); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -43) }
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.method == "GET" })
        XCTAssertNil(n.recoveryPendingDeleteID)
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
    }

    func testOldKnownObjectCannotBeClaimedAsUnknownNewCreation() async throws {
        let n = source(); n.remoteId = "candidate"
        serveCandidate(); let candidate = try await verify(n)
        do { try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .associate, reason: evidence, acknowledged: true); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -46) }
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
    }

    func testConfirmationAndEvidenceAreRequiredBeforeAnyRecoveryMutation() async throws {
        let n = source(); serveCandidate(); let candidate = try await verify(n)
        let requests = MockURLProtocol.requests.count
        do { try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .associate, reason: "", acknowledged: false); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -46) }
        XCTAssertEqual(MockURLProtocol.requests.count, requests)
        XCTAssertTrue(n.recoveryAudit.isEmpty)
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
    }

    func testStaleAssociationConfirmationCannotReplayAfterLocalCommit() async throws {
        let n = source(); serveCandidate(); let candidate = try await verify(n)
        try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .associate, reason: evidence, acknowledged: true)
        let requests = MockURLProtocol.requests.count
        do { try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .deleteCandidate, reason: evidence, acknowledged: true); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -43) }
        XCTAssertEqual(MockURLProtocol.requests.count, requests)
    }

    func testAccountSwitchInvalidatesCandidateAndDoesNotWriteToB() async throws {
        let n = source(); serveCandidate(); let candidate = try await verify(n)
        SyncAuthStub.shared.accountID = "B"; SyncAuthStub.shared.sessionGeneration = UUID()
        let requests = MockURLProtocol.requests.count
        do { try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .deleteCandidate, reason: evidence, acknowledged: true); XCTFail() } catch {}
        XCTAssertEqual(MockURLProtocol.requests.count, requests)
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
    }

    func testRestoringHiddenTombstoneKeepsUnknownIntentAndDoesNotContactGraph() async throws {
        let n = source(deleted: true)
        try await engine.restoreRecoveryLocalOnly(n, reason: evidence, acknowledged: true)
        XCTAssertFalse(n.isDeletedLocally); XCTAssertTrue(n.recoveryPaused)
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
        XCTAssertEqual(n.plainTextContent, "local-newer")
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testExplicitRetryMakesNewPostPreservesOldHistoryAndDoesNotDeleteOldObjects() async throws {
        let n = source(); n.remoteId = "previous-known"
        MockURLProtocol.handler = { request in
            request.httpMethod == "GET" ? .http(status: 200, json: ["id": "test-account"]) : .http(status: 201, json: self.cloud(id: "new-approved"))
        }
        try await engine.retryRecoveryCreate(n, expectedVersion: n.recoveryVersion, reason: evidence, acknowledged: true)
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(n.remoteId, "new-approved"); XCTAssertNil(n.pendingCreateOperationID)
        XCTAssertEqual(n.recoveryRetainedRemoteIDs, ["previous-known"])
        XCTAssertTrue(n.recoveryBlocksAutomaticRecreate)
        XCTAssertEqual(n.recoveryAudit.first?.priorOperationID, "fake-old-operation")
        XCTAssertEqual(n.syncStatus, .synced)
    }

    func testDoubleConfirmedRetryWithSameVersionCannotCreateTwice() async throws {
        let n = source(); let version = n.recoveryVersion
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { request in
            request.httpMethod == "GET" ? .http(status: 200, json: ["id": "test-account"]) : .http(status: 201, json: self.cloud(id: "one-approved"))
        }
        let first = Task { try await self.engine.retryRecoveryCreate(n, expectedVersion: version, reason: self.evidence, acknowledged: true) }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        let second = Task { try await self.engine.retryRecoveryCreate(n, expectedVersion: version, reason: self.evidence, acknowledged: true) }
        try await waitUntil { self.engine.uploadWaiterCount(for: n.id) == 1 }
        MockURLProtocol.releaseNext(); try await first.value
        do { try await second.value; XCTFail() } catch { XCTAssertEqual((error as NSError).code, -43) }
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "POST" }.count, 1)
    }

    func testRetryFailurePreservesNewIntentAndPriorAuditAcrossReload() async throws {
        let n = source()
        MockURLProtocol.handler = { request in
            request.httpMethod == "GET" ? .http(status: 200, json: ["id": "test-account"]) : .http(status: 500, json: [:])
        }
        do { try await engine.retryRecoveryCreate(n, expectedVersion: n.recoveryVersion, reason: evidence, acknowledged: true); XCTFail() } catch {}
        XCTAssertNotNil(n.pendingCreateOperationID)
        XCTAssertNotEqual(n.pendingCreateOperationID, "fake-old-operation")
        let restored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<StickyNote>()).first { !$0.recoveryIsArchive })
        XCTAssertEqual(restored.pendingCreateOperationID, n.pendingCreateOperationID)
        XCTAssertEqual(restored.recoveryAudit.first?.priorOperationID, "fake-old-operation")
    }

    func testAcceptedDeleteLostOnSwitchCanBeReverifiedAbsentAfterReloadWithoutBlindReplay() async throws {
        let n = source(); serveCandidate(); let candidate = try await verify(n)
        MockURLProtocol.holdMethods = ["DELETE"]
        MockURLProtocol.handler = { request in
            if request.url!.path == "/v1.0/me" { return .http(status: 200, json: ["id": "test-account"]) }
            return request.httpMethod == "DELETE" ? .http(status: 204, json: nil) : .http(status: 200, json: self.cloud())
        }
        let task = Task { try await self.engine.confirmRecoveryCandidate(n, candidate: candidate, action: .deleteCandidate, reason: self.evidence, acknowledged: true) }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        XCTAssertEqual(n.recoveryPendingDeleteID, "candidate")
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
        SyncAuthStub.shared.accountID = "B"; SyncAuthStub.shared.sessionGeneration = UUID()
        MockURLProtocol.releaseNext(); do { try await task.value; XCTFail() } catch {}
        let newContext = ModelContext(container)
        let restored = try XCTUnwrap(newContext.fetch(FetchDescriptor<StickyNote>()).first { !$0.recoveryIsArchive })
        XCTAssertEqual(restored.recoveryPendingDeleteID, "candidate")
        SyncAuthStub.shared.accountID = "test-account"; SyncAuthStub.shared.sessionGeneration = UUID()
        MockURLProtocol.holdMethods = []
        MockURLProtocol.handler = { request in
            request.url!.path == "/v1.0/me" ? .http(status: 200, json: ["id": "test-account"]) : .http(status: 404, json: [:])
        }
        let restarted = SyncEngine(authManager: SyncAuthStub.shared)
        let absent = try await restarted.verifyRecoveryCandidate(restored, id: "candidate", kind: .graphNote)
        XCTAssertFalse(absent.exists)
        try await restarted.confirmRecoveryCandidate(restored, candidate: absent, action: .deleteCandidate, reason: evidence, acknowledged: true)
        XCTAssertNil(restored.recoveryPendingDeleteID); XCTAssertNil(restored.pendingCreateOperationID)
        XCTAssertTrue(restored.recoveryPaused); XCTAssertFalse(restored.isDeletedLocally)
        XCTAssertEqual(restored.plainTextContent, "local-newer")
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "DELETE" }.count, 1)
    }

    func testExplicitRetainedDeleteDoesNotResolveSeparateUnknownCreation() async throws {
        let n = source(); n.recoveryRetainedRemoteIDs = ["candidate"]
        serveCandidate(); let candidate = try await verify(n)
        MockURLProtocol.handler = { request in
            if request.url!.path == "/v1.0/me" { return .http(status: 200, json: ["id": "test-account"]) }
            return request.httpMethod == "DELETE" ? .http(status: 204, json: nil) : .http(status: 200, json: self.cloud())
        }
        try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .deleteRetained, reason: evidence, acknowledged: true)
        XCTAssertTrue(n.recoveryRetainedRemoteIDs.isEmpty)
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
        XCTAssertEqual(n.plainTextContent, "local-newer")
    }

    // N2: the debounce task ITSELF owns the held CREATE when new typing occurs.
    func testTypingDoesNotCancelDispatchedDebounceCreateAndQueuesNewRevisionPatch() async throws {
        let n = StickyNote(content: "v1", ownerAccountID: "test-account"); context.insert(n)
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { request in
            request.httpMethod == "POST" ? .http(status: 201, json: self.cloud(id: "created")) : .http(status: 200, json: ["id": "created", "changeKey": "v2-key", "body": ["content": "<div>v2</div>"]])
        }
        engine.scheduleDebouncedPush(for: n.id, in: context)
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        let op = try XCTUnwrap(n.pendingCreateOperationID)
        n.plainTextContent = "v2"; n.modifiedAt = Date().addingTimeInterval(1)
        engine.scheduleDebouncedPush(for: n.id, in: context)
        try await waitUntil { self.engine.uploadWaiterCount(for: n.id) == 1 }
        XCTAssertEqual(MockURLProtocol.cancellationCount, 0)
        XCTAssertEqual(n.pendingCreateOperationID, op)
        MockURLProtocol.releaseNext()
        try await waitUntil { self.engine.activeScheduledPushCount == 0 }
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["POST", "PATCH"])
        XCTAssertEqual(n.plainTextContent, "v2"); XCTAssertEqual(n.syncStatus, .synced)
        XCTAssertNil(n.pendingCreateOperationID)
    }

    func testDeletingDebounceOwnedInFlightCreateKeepsLifecycleUntilKnownDelete() async throws {
        let n = StickyNote(content: "v1", ownerAccountID: "test-account"); context.insert(n)
        MockURLProtocol.holdMethods = ["POST"]
        MockURLProtocol.handler = { request in
            request.httpMethod == "POST" ? .http(status: 201, json: self.cloud(id: "created")) : .http(status: 204, json: nil)
        }
        engine.scheduleDebouncedPush(for: n.id, in: context)
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        try engine.prepareForDeletion(n, modelContext: context)
        MockURLProtocol.releaseNext()
        try await waitUntil { self.engine.activeScheduledPushCount == 0 }
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["POST", "DELETE"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StickyNote>()), 0)
    }

    // N3: one unresolved hidden tombstone does not starve an unrelated safe CREATE.
    func testUnknownTombstoneDoesNotStarveUnrelatedUploadAndStillReportsProblems() async throws {
        let hidden = source(deleted: true)
        let safe = StickyNote(content: "safe", ownerAccountID: "test-account"); context.insert(safe)
        MockURLProtocol.handler = { request in
            request.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 201, json: self.cloud(id: "safe-created"))
        }
        await engine.syncAll(modelContext: context)
        XCTAssertEqual(safe.remoteId, "safe-created"); XCTAssertEqual(safe.syncStatus, .synced)
        XCTAssertEqual(hidden.pendingCreateOperationID, "fake-old-operation"); XCTAssertTrue(hidden.isDeletedLocally)
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET", "POST"])
        assertProblem(); XCTAssertNil(engine.lastSyncDate)
    }

    func testFailedDeleteDoesNotStarveUnrelatedSafeUpload() async throws {
        let tomb = StickyNote(content: "delete", remoteId: "failed-delete", ownerAccountID: "test-account"); tomb.isDeletedLocally = true; context.insert(tomb)
        let safe = StickyNote(content: "safe", ownerAccountID: "test-account"); context.insert(safe)
        MockURLProtocol.handler = { request in
            switch request.httpMethod {
            case "GET": return .http(status: 200, json: ["value": []])
            case "DELETE": return .http(status: 500, json: [:])
            default: return .http(status: 201, json: self.cloud(id: "safe-created"))
            }
        }
        await engine.syncAll(modelContext: context)
        XCTAssertEqual(safe.remoteId, "safe-created")
        XCTAssertEqual(tomb.remoteId, "failed-delete")
        assertProblem(); XCTAssertNil(engine.lastSyncDate)
    }
    func testAssociationRejectsDuplicateRepresentationWithInFlightUpload() async throws {
        let n = source()
        let duplicate = StickyNote(content: "duplicate", remoteId: "candidate", ownerAccountID: "test-account")
        context.insert(duplicate); serveCandidate(); let candidate = try await verify(n)
        MockURLProtocol.holdMethods = ["PATCH"]
        MockURLProtocol.handler = { request in
            if request.url!.path == "/v1.0/me" { return .http(status: 200, json: ["id": "test-account"]) }
            return .http(status: 200, json: self.cloud())
        }
        let pending = Task { try? await self.engine.uploadNote(duplicate, token: "fake") }
        try await waitUntil { MockURLProtocol.heldCount == 1 }
        do { try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .associate, reason: evidence, acknowledged: true); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -46) }
        XCTAssertEqual(n.pendingCreateOperationID, "fake-old-operation")
        MockURLProtocol.releaseNext(); await pending.value
    }

    func testRecoveredAssociationCloudConflictPausesWithoutAutomaticCopyPost() async throws {
        let n = source(); serveCandidate(); let candidate = try await verify(n)
        try await engine.confirmRecoveryCandidate(n, candidate: candidate, action: .associate, reason: evidence, acknowledged: true)
        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in
            var remote = self.cloud(key: "new-cloud-version")
            remote["lastModifiedDateTime"] = "2099-01-01T00:00:00Z"
            return .http(status: 200, json: ["value": [remote]])
        }
        await engine.syncAll(modelContext: context)
        XCTAssertTrue(n.recoveryPaused)
        XCTAssertEqual(n.plainTextContent, "local-newer")
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.method == "GET" })
        XCTAssertFalse(try context.fetch(FetchDescriptor<StickyNote>()).contains { !$0.recoveryPaused && $0.remoteId == nil })
        assertProblem()
    }

}

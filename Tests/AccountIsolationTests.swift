import XCTest
import SwiftData
import AppKit

/// Strict per-account local isolation. Temporary in-memory / temp-dir stores, auth double and
/// MockURLProtocol only: no real database, Keychain, token or Graph traffic.
@MainActor
final class AccountIsolationTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var engine: SyncEngine!
    private var auth: SyncAuthStub { SyncAuthStub.shared }
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var service: AccountIsolationService!

    override func setUp() async throws {
        MockURLProtocol.reset(); URLProtocol.registerClass(MockURLProtocol.self)
        auth.reset()
        let schema = Schema([StickyNote.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        engine = SyncEngine(authManager: auth, debounceNanoseconds: 1_000_000)
        suiteName = "iso-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        service = AccountIsolationService(auth: auth, ledger: AdoptionLedger(defaults: defaults))
    }
    override func tearDown() async throws {
        XCTAssertEqual(MockURLProtocol.heldCount, 0)
        MockURLProtocol.reset(); URLProtocol.unregisterClass(MockURLProtocol.self)
        defaults.removePersistentDomain(forName: suiteName)
        container = nil; engine = nil; service = nil; coordinators = []
    }

    // MARK: helpers
    private func signIn(_ id: String) { auth.isAuthenticated = true; auth.isAuthenticating = false; auth.accountID = id; auth.sessionGeneration = UUID() }
    private func signOut() { auth.isAuthenticated = false; auth.isAuthenticating = false; auth.accountID = nil; auth.sessionGeneration = UUID() }
    @discardableResult private func add(_ text: String, owner: String?, remote: String? = nil) -> StickyNote {
        let n = StickyNote(content: text, remoteId: remote, ownerAccountID: owner, changeKey: remote == nil ? nil : "ck-" + text)
        if remote != nil { n.syncStatus = .synced; n.lastSyncedAt = Date() }
        context.insert(n); try? context.save(); return n
    }
    private func ids(_ notes: [StickyNote]) -> Set<UUID> { Set(notes.map(\.id)) }
    private func all() throws -> [StickyNote] { try context.fetch(FetchDescriptor<StickyNote>()) }
    private func visible(_ scope: ActiveScope) throws -> [StickyNote] { NoteScopeQuery.visible(try all(), in: scope) }
    nonisolated private func listReply(_ request: URLRequest, created: String = "R-new") -> MockURLProtocol.Reply {
        switch request.httpMethod ?? "GET" {
        case "GET": return .http(status: 200, json: ["value": []])
        case "POST": return .http(status: 201, json: ["id": created, "changeKey": "CK", "body": ["contentType": "html", "content": "x"]])
        default: return .http(status: 204, json: nil)
        }
    }

    // MARK: scope resolution (③ signed-out / unconfirmed)
    func testScopeResolutionTable() {
        XCTAssertEqual(ActiveScope.resolve(isAuthenticated: false, isAuthenticating: false, accountID: nil), .unlinkedLocal)
        XCTAssertEqual(ActiveScope.resolve(isAuthenticated: false, isAuthenticating: true, accountID: nil), .blocked)
        XCTAssertEqual(ActiveScope.resolve(isAuthenticated: true, isAuthenticating: false, accountID: nil), .blocked)
        XCTAssertEqual(ActiveScope.resolve(isAuthenticated: true, isAuthenticating: false, accountID: ""), .blocked)
        XCTAssertEqual(ActiveScope.resolve(isAuthenticated: true, isAuthenticating: false, accountID: "A"), .account("A"))
        XCTAssertEqual(ActiveScope.resolve(isAuthenticated: false, isAuthenticating: false, accountID: "A"), .blocked)
        XCTAssertEqual(ActiveScope.resolve(isAuthenticated: true, isAuthenticating: false, accountID: StickyNote.unlinkedOwnerMarker), .blocked)
    }

    func testStubScopeFollowsAuthStateAndUnconfirmedShowsNothingAndCannotCreate() throws {
        add("A", owner: "A"); add("local", owner: StickyNote.unlinkedOwnerMarker); add("legacy", owner: nil)
        auth.isAuthenticated = true; auth.accountID = nil
        XCTAssertEqual(auth.activeScope, .blocked)
        XCTAssertTrue(try visible(auth.activeScope).isEmpty, "身份未核实不得展示任何账号或本地数据")
        XCTAssertNil(StickyNote.make(in: auth.activeScope))
        auth.isAuthenticated = false; auth.isAuthenticating = true
        XCTAssertEqual(auth.activeScope, .blocked)
        XCTAssertTrue(try visible(auth.activeScope).isEmpty)
    }

    // MARK: visibility matrix (①)
    func testVisibilityMatrixAcrossEveryScope() throws {
        let a = add("alpha", owner: "A"), b = add("beta", owner: "B")
        let local = add("local", owner: StickyNote.unlinkedOwnerMarker)
        let legacy = add("legacy", owner: nil), legacyCloud = add("legacy-cloud", owner: nil, remote: "R-old")
        let tomb = add("tomb", owner: "A"); tomb.isDeletedLocally = true
        XCTAssertEqual(ids(try visible(.account("A"))), [a.id])
        XCTAssertEqual(ids(try visible(.account("B"))), [b.id])
        XCTAssertEqual(ids(try visible(.account("C"))), [])
        XCTAssertEqual(ids(try visible(.unlinkedLocal)), [local.id])
        XCTAssertEqual(ids(try visible(.blocked)), [])
        for scope in [ActiveScope.account("A"), .account("B"), .unlinkedLocal, .blocked] {
            XCTAssertFalse(ids(try visible(scope)).contains(legacy.id), "旧库未归属数据对任何范围隐藏")
            XCTAssertFalse(ids(try visible(scope)).contains(legacyCloud.id))
        }
        XCTAssertEqual(ids(NoteScopeQuery.quarantined(try all())), [legacy.id, legacyCloud.id])
        // search is scoped too
        XCTAssertEqual(NoteScopeQuery.search(try all(), text: "ALP", in: .account("A")).map(\.id), [a.id])
        XCTAssertTrue(NoteScopeQuery.search(try all(), text: "alpha", in: .account("B")).isEmpty)
        XCTAssertTrue(NoteScopeQuery.search(try all(), text: "legacy", in: .account("A")).isEmpty)
        XCTAssertTrue(NoteScopeQuery.search(try all(), text: "alpha", in: .unlinkedLocal).isEmpty)
    }

    func testNewNotesAreStampedAtCreation() {
        XCTAssertEqual(StickyNote.make(in: .account("A"))?.ownerAccountID, "A")
        XCTAssertEqual(StickyNote.make(in: .unlinkedLocal)?.ownerAccountID, StickyNote.unlinkedOwnerMarker)
        XCTAssertEqual(StickyNote.make(in: .unlinkedLocal)?.ownership, .unlinkedLocal)
        XCTAssertNil(StickyNote.make(in: .blocked))
    }

    // MARK: A → B → A full chain (②)
    func testAtoBtoAFullChainListSearchWindowsQueuesTombstonesRecoveryAndExport() async throws {
        signIn("A")
        let a1 = StickyNote.make(in: auth.activeScope, content: "A-secret-one")!; a1.isOpen = true; a1.windowX = 11; a1.windowY = 22
        a1.remoteId = "A-remote-1"; a1.changeKey = "kA"; a1.syncStatus = .synced
        let a2 = StickyNote.make(in: auth.activeScope, content: "A-secret-two")!
        a2.syncStatus = .pendingUpload
        let aTomb = StickyNote.make(in: auth.activeScope, content: "A-deleted")!
        aTomb.remoteId = "A-tombstone-remote"; aTomb.isDeletedLocally = true; aTomb.syncStatus = .error
        let aCleanup = StickyNote.make(in: auth.activeScope, content: "A-cleanup")!
        aCleanup.remoteId = "A-new"; aCleanup.pendingCleanupRemoteIDs = ["A-retired-id"]; aCleanup.syncStatus = .synced
        let aUnknown = StickyNote.make(in: auth.activeScope, content: "A-unknown-create")!
        aUnknown.pendingCreateOperationID = "op-A"; aUnknown.syncStatus = .error
        [a1, a2, aTomb, aCleanup, aUnknown].forEach { context.insert($0) }; try context.save()
        let aIDs = ids([a1, a2, aTomb, aCleanup, aUnknown])
        func fingerprint(_ n: StickyNote) -> String {
            [n.plainTextContent, n.ownerAccountID ?? "-", n.remoteId ?? "-", n.changeKey ?? "-", n.syncStatusRaw, String(n.isDeletedLocally),
             String(n.windowX), String(n.windowY), String(n.isOpen), n.pendingCleanupIDsData.map { $0.base64EncodedString() } ?? "-",
             n.pendingCreateOperationID ?? "-"].joined(separator: "|")
        }
        let before = Dictionary(uniqueKeysWithValues: [a1, a2, aTomb, aCleanup, aUnknown].map { ($0.id, fingerprint($0)) })

        // → B
        signIn("B")
        XCTAssertTrue(try visible(auth.activeScope).isEmpty, "B 不得看到 A 的任何便笺")
        XCTAssertTrue(NoteScopeQuery.search(try all(), text: "A-secret", in: auth.activeScope).isEmpty)
        XCTAssertTrue(engine.recoveryRecords(from: try all()).isEmpty, "待核对页只含当前账号")
        let plan = NoteScopeQuery.windowPlan(notes: try all(), scope: auth.activeScope, openWindowIDs: [a1.id])
        XCTAssertEqual(plan, NoteScopeQuery.WindowPlan(toClose: [a1.id], toRestore: []), "切号时 A 的窗口关闭，B 不恢复它")
        XCTAssertThrowsError(try engine.exportRecoveryContent(a1), "B 不能经恢复导出读 A 的数据")
        MockURLProtocol.handler = { self.listReply($0) }
        let bNote = StickyNote.make(in: auth.activeScope, content: "B-only")!
        context.insert(bNote); try context.save()
        await engine.syncAll(modelContext: context)
        let methods = MockURLProtocol.requests.map(\.method)
        XCTAssertEqual(methods.filter { $0 == "POST" }.count, 1, "B 只上传自己的 1 条")
        XCTAssertFalse(methods.contains("DELETE"), "B 不得删除 A 的墓碑/待清理对象")
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.url.absoluteString.contains("A-tombstone-remote") || $0.url.absoluteString.contains("A-retired-id") || $0.url.absoluteString.contains("A-remote-1") })
        for r in MockURLProtocol.requests {
            let body = r.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertFalse(body.contains("A-secret") || body.contains("A-deleted") || body.contains("A-cleanup"), "B 的请求体不含 A 内容")
        }
        for n in try all() where aIDs.contains(n.id) { XCTAssertEqual(fingerprint(n), before[n.id], "A 的数据在 B 登录期间原样不变") }
        XCTAssertEqual(ids(try visible(.account("B"))), [bNote.id])

        // → A again
        MockURLProtocol.reset(); signIn("A")
        MockURLProtocol.handler = { self.listReply($0) }
        XCTAssertEqual(ids(try visible(auth.activeScope)), [a1.id, a2.id, aCleanup.id, aUnknown.id], "切回 A 原样可见（墓碑仍隐藏）")
        XCTAssertEqual(NoteScopeQuery.search(try all(), text: "secret-two", in: auth.activeScope).map(\.id), [a2.id])
        let restore = NoteScopeQuery.windowPlan(notes: try all(), scope: auth.activeScope, openWindowIDs: [])
        XCTAssertEqual(restore.toRestore, [a1.id], "切回 A 恢复切号时已打开的窗口")
        XCTAssertEqual(a1.windowX, 11); XCTAssertEqual(a1.windowY, 22)
        XCTAssertEqual(engine.recoveryRecords(from: try all()).map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [aUnknown.id])
        await engine.syncAll(modelContext: context)
        let a = MockURLProtocol.requests
        XCTAssertTrue(a.contains { $0.method == "DELETE" && $0.url.absoluteString.contains("A-retired-id") }, "A 自己的清理队列仍由 A 执行")
        XCTAssertTrue(a.contains { $0.method == "DELETE" && $0.url.absoluteString.contains("A-tombstone-remote") })
        XCTAssertFalse(a.contains { ($0.body.flatMap { String(data: $0, encoding: .utf8) } ?? "").contains("B-only") })
        XCTAssertEqual(bNote.plainTextContent, "B-only"); XCTAssertEqual(bNote.remoteId, "R-new"); XCTAssertEqual(bNote.ownerAccountID, "B")
    }

    func testBNeverUploadsOrDeletesAnOtherAccountsPendingNotesEvenWhenIdenticalRemoteIDs() async throws {
        let a = add("A-pending", owner: "A"); a.syncStatus = .pendingUpload
        let legacy = add("legacy-pending", owner: nil); legacy.syncStatus = .pendingUpload
        let local = add("local-pending", owner: StickyNote.unlinkedOwnerMarker); local.syncStatus = .pendingUpload
        signIn("B")
        MockURLProtocol.handler = { self.listReply($0) }
        await engine.syncAll(modelContext: context)
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET"])
        XCTAssertEqual(a.syncStatus, .pendingUpload); XCTAssertEqual(legacy.syncStatus, .pendingUpload); XCTAssertEqual(local.syncStatus, .pendingUpload)
        do { try await engine.uploadNote(a, token: "t"); XCTFail("foreign upload must throw") }
        catch { XCTAssertEqual((error as NSError).code, -21) }
        do { try await engine.uploadNote(local, token: "t"); XCTFail("no-account upload must throw") }
        catch { XCTAssertEqual((error as NSError).code, -21) }
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET"])
    }

    // MARK: signed-out & first-sign-in adoption (②③)
    func testSignedOutScopeShowsOnlyNoAccountNotesAndNeverSyncs() async throws {
        let acct = add("A-data", owner: "A"); _ = acct
        signOut()
        let n = StickyNote.make(in: auth.activeScope, content: "offline-note")!
        context.insert(n); try context.save()
        XCTAssertEqual(try visible(auth.activeScope).map(\.id), [n.id])
        await engine.syncAll(modelContext: context)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        engine.scheduleDebouncedPush(for: n.id, in: context)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testFirstSignInPromptDeclineKeepsNotesLocalAndAsksOnlyAboutNewOnesLater() async throws {
        signOut()
        let n1 = StickyNote.make(in: auth.activeScope, content: "L1")!, n2 = StickyNote.make(in: auth.activeScope, content: "L2")!
        context.insert(n1); context.insert(n2); try context.save()
        let legacy = add("legacy", owner: nil)
        signIn("A")
        let prompt = try XCTUnwrap(try service.pendingPrompt(modelContext: context))
        XCTAssertEqual(Set(prompt.noteIDs), [n1.id, n2.id], "弹窗只含无账号便笺，不含隔离区旧数据")
        XCTAssertFalse(prompt.noteIDs.contains(legacy.id))
        // before confirmation: nothing merged, nothing uploaded, not shown as account data
        MockURLProtocol.handler = { self.listReply($0) }
        await engine.syncAll(modelContext: context)
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET"])
        XCTAssertEqual(n1.ownership, .unlinkedLocal)
        XCTAssertTrue(try visible(.account("A")).isEmpty)
        // decline
        try service.decline(prompt)
        XCTAssertNil(try service.pendingPrompt(modelContext: context))
        XCTAssertEqual(n1.ownerAccountID, StickyNote.unlinkedOwnerMarker); XCTAssertEqual(n2.ownerAccountID, StickyNote.unlinkedOwnerMarker)
        XCTAssertEqual(ids(NoteScopeQuery.unlinked(try all())), [n1.id, n2.id], "拒绝后不丢失")
        // sign-out: they are visible again, untouched
        signOut()
        XCTAssertEqual(ids(try visible(auth.activeScope)), [n1.id, n2.id])
        // re-sign in as A: no repeat prompt
        signIn("A")
        XCTAssertNil(try service.pendingPrompt(modelContext: context))
        // new no-account note created while signed out -> ask again, only about it
        signOut()
        let n3 = StickyNote.make(in: auth.activeScope, content: "L3")!; context.insert(n3); try context.save()
        signIn("A")
        XCTAssertEqual(try service.pendingPrompt(modelContext: context)?.noteIDs, [n3.id])
        // another account is asked about everything independently
        signIn("B")
        XCTAssertEqual(Set(try XCTUnwrap(try service.pendingPrompt(modelContext: context)).noteIDs), [n1.id, n2.id, n3.id])
    }

    func testAcceptStampsOnlyPromptedNotesAndOnlyThenUploads() async throws {
        signOut()
        let n1 = StickyNote.make(in: auth.activeScope, content: "L1")!, n2 = StickyNote.make(in: auth.activeScope, content: "L2")!
        context.insert(n1); context.insert(n2); try context.save()
        signIn("A")
        let prompt = try XCTUnwrap(try service.pendingPrompt(modelContext: context))
        let late = StickyNote.make(in: .unlinkedLocal, content: "created-after-dialog-opened")!
        context.insert(late); try context.save()
        XCTAssertEqual(try service.accept(prompt, modelContext: context), 2)
        XCTAssertEqual(n1.ownerAccountID, "A"); XCTAssertEqual(n1.syncStatus, .pendingUpload)
        XCTAssertEqual(late.ownership, .unlinkedLocal, "弹窗之外的便笺不被带入")
        MockURLProtocol.handler = { self.listReply($0) }
        await engine.syncAll(modelContext: context)
        let posts = MockURLProtocol.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertFalse(posts.contains { String(data: $0.body ?? Data(), encoding: .utf8)?.contains("created-after-dialog") == true })
        XCTAssertEqual(ids(try visible(.account("A"))), [n1.id, n2.id])
        // later: late is a candidate again for the same account (never asked)
        XCTAssertEqual(try service.pendingPrompt(modelContext: context)?.noteIDs, [late.id])
    }

    func testStalePromptAfterAccountSwitchCannotStampNotes() throws {
        signOut()
        let n = StickyNote.make(in: .unlinkedLocal, content: "L")!; context.insert(n); try context.save()
        signIn("A")
        let prompt = try XCTUnwrap(try service.pendingPrompt(modelContext: context))
        signIn("B")
        XCTAssertThrowsError(try service.accept(prompt, modelContext: context))
        XCTAssertThrowsError(try service.decline(prompt))
        XCTAssertEqual(n.ownership, .unlinkedLocal)
        XCTAssertTrue(service.ledger.decisions(for: "A").isEmpty)
        signOut()
        XCTAssertNil(try service.pendingPrompt(modelContext: context), "未登录不弹窗")
        auth.isAuthenticated = true; auth.accountID = nil
        XCTAssertNil(try service.pendingPrompt(modelContext: context), "身份未确认不弹窗")
        XCTAssertThrowsError(try service.adoptUnlinked(modelContext: context))
    }

    func testManualSettingsEntryAdoptsEvenAfterDeclineButNeverLegacyOrDeleted() throws {
        signOut()
        let n = StickyNote.make(in: .unlinkedLocal, content: "L")!; let gone = StickyNote.make(in: .unlinkedLocal, content: "gone")!
        gone.isDeletedLocally = true
        context.insert(n); context.insert(gone); try context.save()
        let legacy = add("legacy", owner: nil)
        signIn("A")
        try service.decline(try XCTUnwrap(try service.pendingPrompt(modelContext: context)))
        XCTAssertEqual(try service.adoptUnlinked(modelContext: context), 1)
        XCTAssertEqual(n.ownerAccountID, "A"); XCTAssertEqual(gone.ownership, .unlinkedLocal); XCTAssertNil(legacy.ownerAccountID)
    }

    // MARK: persistence across restart (退出重开)
    func testRestartKeepsIsolationAndDeclinedState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("restart.store")
        let schema = Schema([StickyNote.self])
        var declinedID: UUID!
        do {
            let c = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let ctx = ModelContext(c)
            let local = StickyNote.make(in: .unlinkedLocal, content: "local")!, a = StickyNote.make(in: .account("A"), content: "A")!
            let legacy = StickyNote(content: "legacy")
            [local, a, legacy].forEach { ctx.insert($0) }; try ctx.save()
            declinedID = local.id
            signIn("A")
            let svc = AccountIsolationService(auth: auth, ledger: AdoptionLedger(defaults: defaults))
            try svc.decline(try XCTUnwrap(try svc.pendingPrompt(modelContext: ctx)))
        }
        // "relaunch": fresh container + fresh service/ledger over the same defaults suite
        let c2 = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let notes = try c2.mainContext.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(NoteScopeQuery.visible(notes, in: .account("A")).map(\.plainTextContent), ["A"])
        XCTAssertEqual(NoteScopeQuery.visible(notes, in: .account("B")).count, 0)
        XCTAssertEqual(NoteScopeQuery.visible(notes, in: .unlinkedLocal).map(\.plainTextContent), ["local"])
        XCTAssertEqual(NoteScopeQuery.quarantined(notes).map(\.plainTextContent), ["legacy"])
        let svc2 = AccountIsolationService(auth: auth, ledger: AdoptionLedger(defaults: defaults))
        XCTAssertEqual(svc2.ledger.decisions(for: "A")[declinedID], .declined)
        XCTAssertNil(try svc2.pendingPrompt(modelContext: c2.mainContext), "已拒绝状态重启后保留")
    }

    // MARK: legacy / migration (④⑥)
    func testLegacyNoTraceClaimIsPerItemExplicitAndCloudTraceCannotBeClaimedOnlyCopied() throws {
        let plain = add("legacy-plain", owner: nil)
        let cloud = add("legacy-cloud", owner: nil, remote: "R-old"); cloud.webNoteJSON = "{}"
        XCTAssertFalse(plain.hasCloudTrace); XCTAssertTrue(cloud.hasCloudTrace)
        signOut()
        XCTAssertThrowsError(try service.claimLegacy(plain, to: .currentAccount, modelContext: context), "未登录不能归入账号")
        signIn("A")
        XCTAssertThrowsError(try service.claimLegacy(cloud, to: .currentAccount, modelContext: context))
        XCTAssertThrowsError(try service.claimLegacy(cloud, to: .noAccountLocal, modelContext: context))
        XCTAssertNil(cloud.ownerAccountID); XCTAssertEqual(cloud.remoteId, "R-old"); XCTAssertEqual(cloud.webNoteJSON, "{}")
        let copy = try service.copyLegacyToCurrentAccount(cloud, modelContext: context)
        XCTAssertEqual(copy.ownerAccountID, "A"); XCTAssertNil(copy.remoteId); XCTAssertNil(copy.changeKey); XCTAssertNil(copy.webNoteJSON)
        XCTAssertEqual(copy.plainTextContent, "legacy-cloud"); XCTAssertEqual(copy.syncStatus, .pendingUpload)
        XCTAssertNil(cloud.ownerAccountID, "原件保持隔离，未被改动"); XCTAssertEqual(cloud.remoteId, "R-old")
        XCTAssertEqual(NoteScopeQuery.quarantined(try all()).count, 2, "plain 与 cloud 仍在隔离区（copy 是新建的 A 范围便笺）")
        try service.claimLegacy(plain, to: .currentAccount, modelContext: context)
        XCTAssertEqual(plain.ownerAccountID, "A")
        XCTAssertThrowsError(try service.claimLegacy(plain, to: .currentAccount, modelContext: context), "已非隔离区")
        let other = add("legacy-other", owner: nil)
        signOut()
        try service.claimLegacy(other, to: .noAccountLocal, modelContext: context)
        XCTAssertEqual(try visible(.unlinkedLocal).map(\.id), [other.id])
    }

    func testLegacyNeverEntersFirstSignInPromptOrSyncPaths() async throws {
        let legacy = add("legacy", owner: nil); legacy.syncStatus = .pendingUpload
        let legacyTomb = add("legacy-tomb", owner: nil, remote: "R-legacy"); legacyTomb.isDeletedLocally = true
        signIn("A")
        XCTAssertNil(try service.pendingPrompt(modelContext: context))
        MockURLProtocol.handler = { self.listReply($0) }
        await engine.syncAll(modelContext: context)
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET"], "旧数据不上传、不删除云端")
        XCTAssertEqual(legacyTomb.remoteId, "R-legacy")
    }

    func testSchemaIsUnchangedSoOlderBuildsCanStillOpenTheStoreAndMarkerNeverMatchesAnAccount() throws {
        let names = Schema([StickyNote.self]).entities.first!.properties.map(\.name).sorted()
        let c34d2e7 = ["attributedContentData", "audioRecordings", "changeKey", "colorRawValue", "createdAt", "id", "isDeletedLocally", "isOpen",
            "lastSyncedAt", "modifiedAt", "ownerAccountID", "pendingCleanupIDsData", "pendingCreateEndpoint", "pendingCreateOperationID",
            "pendingCreateStartedAt", "plainTextContent", "recoveryAuditData", "recoveryBlocksAutomaticRecreate", "recoveryIsArchive",
            "recoveryPaused", "recoveryPendingDeleteID", "recoveryPendingDeleteKindRaw", "recoveryRetainedIDsData", "recoveryVersion",
            "remoteId", "syncStatusRaw", "webNoteJSON", "windowHeight", "windowWidth", "windowX", "windowY"].sorted()
        XCTAssertEqual(names, c34d2e7, "本分支不新增/删除任何存储字段：c34d2e7 及更早含 owner 的版本可直接读同一库")
        XCTAssertFalse(UUID(uuidString: StickyNote.unlinkedOwnerMarker) != nil, "标记不可能是 Graph GUID，旧同步路径视其为「他人账号」而跳过")
    }

    func testPreIsolationSafetyBackupIsCopyOnlyAndNeverOverwrites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("default.store")
        try Data("main-v1".utf8).write(to: store)
        try Data("wal-v1".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        let created = try StoreSafetyBackup.createIfNeeded(storeURL: store)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(try Data(contentsOf: store), Data("main-v1".utf8), "原库不变")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path + ".pre-account-isolation")), Data("main-v1".utf8))
        try Data("main-v2".utf8).write(to: store)
        XCTAssertTrue(try StoreSafetyBackup.createIfNeeded(storeURL: store).isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path + ".pre-account-isolation")), Data("main-v1".utf8), "已有备份不会被覆盖")
        XCTAssertTrue(try StoreSafetyBackup.createIfNeeded(storeURL: folder.appendingPathComponent("missing.store")).isEmpty)
    }

    // MARK: in-flight (⑤)
    func testSwitchDuringPullCannotWriteNewScopeOrUpload() async throws {
        signIn("A")
        let a = add("A-edit", owner: "A"); a.syncStatus = .pendingUpload
        MockURLProtocol.responseDelay = 0.15
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["value": [["id": "R-A-cloud", "changeKey": "K", "subject": "s", "body": ["contentType": "html", "content": "<div>cloud-of-A</div>"],
                                                                                 "createdDateTime": "2026-01-01T00:00:00Z", "lastModifiedDateTime": "2026-01-02T00:00:00Z"]]]) }
        let task = Task { await self.engine.syncAll(modelContext: self.context) }
        for _ in 0..<200 { if !MockURLProtocol.requests.isEmpty { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        signIn("B")
        await task.value
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET"])
        XCTAssertEqual(try all().count, 1, "A 的响应不得在 B 登录后写入任何范围")
        XCTAssertTrue(try visible(.account("B")).isEmpty)
        XCTAssertEqual(a.syncStatus, .pendingUpload)
    }

    func testDebouncedPushScheduledForAIsDroppedAfterSwitchToBAndToSignedOut() async throws {
        signIn("A")
        let a = add("A-typing", owner: "A"); a.syncStatus = .pendingUpload
        engine.scheduleDebouncedPush(for: a.id, in: context)
        signOut()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        signIn("A")
        engine.scheduleDebouncedPush(for: a.id, in: context)
        signIn("B")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    // MARK: export (S3② + ① 导入导出)
    func testExportWorksSignedOutAndOfflineWithinScopeAndNeedsAckOutside() throws {
        let local = add("local-one", owner: StickyNote.unlinkedOwnerMarker)
        let a = add("A-one", owner: "A"); a.isDeletedLocally = true
        let legacy = add("legacy-one", owner: nil)
        signOut()
        let ok = try LocalExporter.export(try all().filter { $0.id == local.id }, scope: auth.activeScope, acknowledgedOutOfScope: false)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: ok) as? [String: Any])?["includesOutOfScopeData"] as? Bool, false)
        XCTAssertThrowsError(try LocalExporter.export([a], scope: auth.activeScope, acknowledgedOutOfScope: false)) {
            XCTAssertTrue($0 is IsolationError)
        }
        XCTAssertThrowsError(try LocalExporter.export([legacy], scope: auth.activeScope, acknowledgedOutOfScope: false))
        let confirmed = try LocalExporter.export([a, legacy], scope: auth.activeScope, acknowledgedOutOfScope: true)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: confirmed) as? [String: Any])
        XCTAssertEqual(json["includesOutOfScopeData"] as? Bool, true)
        XCTAssertEqual((json["notes"] as? [[String: Any]])?.compactMap { $0["plainText"] as? String }.sorted(), ["A-one", "legacy-one"])
        XCTAssertNil(json["access_token"])
        // in-scope hidden tombstone exports without ack when its scope is active
        signIn("A")
        XCTAssertNoThrow(try LocalExporter.export([a], scope: auth.activeScope, acknowledgedOutOfScope: false))
        // identity unconfirmed => everything is out of scope
        auth.accountID = nil
        XCTAssertThrowsError(try LocalExporter.export([a], scope: auth.activeScope, acknowledgedOutOfScope: false))
        XCTAssertTrue(MockURLProtocol.requests.isEmpty, "导出完全不联网")
    }

    // MARK: S2 per-record corrupt journal
    func testCorruptJournalIsolatesOnlyThatNoteAndOtherNotesStillSyncWithHonestStatus() async throws {
        signIn("A"); engine.lastSyncDate = nil
        let bad = add("bad", owner: "A", remote: "R-bad"); bad.pendingCleanupIDsData = Data("not-json".utf8); bad.syncStatus = .pendingUpload
        let good = add("good", owner: "A"); good.syncStatus = .pendingUpload
        let tomb = add("tomb", owner: "A", remote: "R-tomb"); tomb.isDeletedLocally = true; tomb.syncStatus = .error
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [["id": "R-new-cloud", "changeKey": "K", "subject": "s", "body": ["contentType": "html", "content": "<div>cloud-new</div>"],
                    "createdDateTime": "2026-01-01T00:00:00Z", "lastModifiedDateTime": "2026-01-02T00:00:00Z"]]])
            }
            return self.listReply(request, created: "R-good")
        }
        await engine.syncAll(modelContext: context)
        let r = MockURLProtocol.requests
        XCTAssertEqual(r.filter { $0.method == "POST" }.count, 1, "无关便笺照常上传")
        XCTAssertTrue(r.contains { $0.method == "DELETE" && $0.url.absoluteString.contains("R-tomb") }, "无关墓碑照常清理")
        XCTAssertFalse(r.contains { $0.url.absoluteString.contains("R-bad") }, "损坏记录不上传、不删除")
        XCTAssertEqual(good.remoteId, "R-good"); XCTAssertEqual(bad.pendingCleanupIDsData, Data("not-json".utf8))
        XCTAssertEqual(try all().filter { $0.remoteId == "R-new-cloud" }.count, 0, "损坏日志存在时不导入云端新便笺，避免复活已退役对象")
        guard case .error(let message) = engine.state else { return XCTFail("必须诚实显示未完成") }
        XCTAssertTrue(message.contains("同步日志损坏") && message.contains("1 条云端新便笺暂未导入"), message)
        XCTAssertNil(engine.lastSyncDate)
    }

    // MARK: S3-A recreate guard
    func testRecoveredBindingGuardClearsOnVerifiedPatchAndStaysOnFailureWithExplicitDegradation() async throws {
        signIn("A")
        let n = add("edit", owner: "A", remote: "R-bound"); n.recoveryBlocksAutomaticRecreate = true; n.syncStatus = .pendingUpload
        MockURLProtocol.handler = { _ in .http(status: 403, json: [:]) }
        engine = SyncEngine(authManager: auth)
        for _ in 0..<2 {
            do { try await engine.uploadNote(n, token: "t", retryAuthOnFailure: false); XCTFail() } catch { XCTAssertEqual((error as NSError).code, -42) }
        }
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.method == "POST" || $0.method == "DELETE" }, "守卫期间不自动重建")
        XCTAssertThrowsError(try engine.allowReplacementSync(n, reason: "ok", acknowledged: false))
        try engine.allowReplacementSync(n, reason: "no ShortNotes for this session, accept replacement", acknowledged: true)
        XCTAssertFalse(n.recoveryBlocksAutomaticRecreate); XCTAssertEqual(n.recoveryAudit.last?.action, "allow-replacement-sync-user-confirmed")
        MockURLProtocol.reset()
        MockURLProtocol.handler = { request in
            switch request.httpMethod ?? "" {
            case "PATCH": return .http(status: 403, json: [:])
            case "POST": return .http(status: 201, json: ["id": "R-replaced", "changeKey": "CK2", "body": ["content": "x"]])
            default: return .http(status: 204, json: nil)
            }
        }
        try await engine.uploadNote(n, token: "t", retryAuthOnFailure: false)
        XCTAssertEqual(n.remoteId, "R-replaced")
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["PATCH", "GET", "POST", "DELETE"], "未改色：替换前只读旧对象的原始颜色属性")
        // verified 2xx PATCH clears the guard automatically
        let m = add("patch-ok", owner: "A", remote: "R-ok"); m.recoveryBlocksAutomaticRecreate = true; m.syncStatus = .pendingUpload
        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "R-ok", "changeKey": "CK9", "body": ["content": "<div>patch-ok</div>"]]) }
        try await engine.uploadNote(m, token: "t", retryAuthOnFailure: false)
        XCTAssertFalse(m.recoveryBlocksAutomaticRecreate); XCTAssertEqual(m.syncStatus, .synced)
    }
    // MARK: unverified (provisional cached) identity authorises nothing (follow-up #3)
    func testUnverifiedIdentityBlocksSyncAdoptionClaimAndCopyUntilConfirmed() async throws {
        signIn("A")
        let local = add("local", owner: StickyNote.unlinkedOwnerMarker)
        let legacy = add("legacy", owner: nil)
        let legacyCloud = add("legacy-cloud", owner: nil, remote: "R-old")
        let mine = add("mine", owner: "A"); mine.syncStatus = .pendingUpload
        auth.isIdentityVerified = false
        XCTAssertEqual(auth.activeScope, .account("A"), "本地仅显示缓存账号")
        XCTAssertNil(try service.pendingPrompt(modelContext: context))
        XCTAssertThrowsError(try service.adoptUnlinked(modelContext: context))
        XCTAssertThrowsError(try service.claimLegacy(legacy, to: .currentAccount, modelContext: context))
        XCTAssertThrowsError(try service.copyLegacyToCurrentAccount(legacyCloud, modelContext: context))
        XCTAssertEqual(local.ownership, .unlinkedLocal)
        XCTAssertEqual(legacy.ownership, .legacyUnknown)
        MockURLProtocol.handler = { [self] in listReply($0) }
        await engine.syncAll(modelContext: context)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty, "未复核身份：不得发任何 Graph 请求")
        XCTAssertEqual(mine.syncStatus, .pendingUpload)
        // 复核通过后恢复
        auth.isIdentityVerified = true
        XCTAssertNotNil(try service.pendingPrompt(modelContext: context))
        XCTAssertNoThrow(try service.claimLegacy(legacy, to: .currentAccount, modelContext: context))
    }
    // MARK: app-level first-login prompt (follow-up #4 Esc ≠ permanent refusal, #5 no list window needed)

    @MainActor final class FakePresenter: AdoptionPromptPresenting {
        var choice: AdoptionChoice = .skip
        var queue: [AdoptionChoice] = []          // answers consumed first, then `choice`
        var shown: [AdoptionPromptInfo] = []
        var beforeReturn: (() -> Void)?
        func present(_ info: AdoptionPromptInfo) async -> AdoptionChoice {
            shown.append(info)
            let hook = beforeReturn; beforeReturn = nil; hook?()
            return queue.isEmpty ? choice : queue.removeFirst()
        }
    }
    private var coordinators: [AdoptionPromptCoordinator] = []   // production holds it in a singleton
    private func coordinator(_ presenter: FakePresenter, accepted: ((ModelContext) -> Void)? = nil) -> AdoptionPromptCoordinator {
        let c = AdoptionPromptCoordinator(auth: auth, service: service, accountLabel: { "a@example.test" })
        coordinators.append(c)
        c.start(context: context, presenter: presenter, afterAccept: { ctx in accepted?(ctx) })
        return c
    }
    private func settle() async { for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) } }

    func testEscOrNotNowSkipsThisTimeOnlyAndNothingIsRecorded() async throws {
        let n = add("local", owner: StickyNote.unlinkedOwnerMarker)
        signIn("A")
        let p = FakePresenter(); p.choice = .skip          // Esc / close / "Not Now"
        let c = coordinator(p)
        await settle()
        XCTAssertEqual(p.shown.count, 1)
        XCTAssertEqual(p.shown.first?.count, 1)
        XCTAssertTrue(service.ledger.decisions(for: "A").isEmpty, "Esc 不得写入任何永久拒绝记录")
        XCTAssertEqual(n.ownership, .unlinkedLocal)
        XCTAssertEqual(n.syncStatus, .pendingUpload)       // untouched default
        await c.evaluate(); await settle()
        XCTAssertEqual(p.shown.count, 1, "同一次登录内不循环重复询问")
        // 下次启动（新的协调器）仍会再问
        let p2 = FakePresenter(); p2.choice = .skip
        _ = coordinator(p2); await settle()
        XCTAssertEqual(p2.shown.count, 1, "下次启动/重新登录仍会再次询问")
        XCTAssertNotNil(try service.pendingPrompt(modelContext: context))
    }

    func testExplicitDeclineIsRemembered() async throws {
        let n = add("local", owner: StickyNote.unlinkedOwnerMarker)
        signIn("A")
        let p = FakePresenter(); p.choice = .decline
        _ = coordinator(p); await settle()
        XCTAssertEqual(service.ledger.decisions(for: "A")[n.id], .declined)
        XCTAssertEqual(n.ownership, .unlinkedLocal, "拒绝不改动便笺")
        let p2 = FakePresenter()
        _ = coordinator(p2); await settle()
        XCTAssertTrue(p2.shown.isEmpty, "显式拒绝之后不再询问同一批便笺")
    }

    func testAcceptAdoptsAndTriggersSync() async throws {
        let n = add("local", owner: StickyNote.unlinkedOwnerMarker)
        signIn("A")
        var synced = 0
        let p = FakePresenter(); p.choice = .accept
        _ = coordinator(p, accepted: { _ in synced += 1 }); await settle()
        XCTAssertEqual(n.ownerAccountID, "A")
        XCTAssertEqual(n.syncStatus, .pendingUpload)
        XCTAssertEqual(service.ledger.decisions(for: "A")[n.id], .accepted)
        XCTAssertEqual(synced, 1)
    }

    func testPromptDoesNotDependOnAnyWindowAndFollowsAuthChangesIncludingVerification() async throws {
        let n = add("local", owner: StickyNote.unlinkedOwnerMarker)
        signOut()
        let p = FakePresenter(); p.choice = .skip
        _ = coordinator(p); await settle()                 // no view / window exists anywhere in this test
        XCTAssertTrue(p.shown.isEmpty, "未登录不询问")
        signIn("A"); auth.isIdentityVerified = false
        await settle()
        XCTAssertTrue(p.shown.isEmpty, "身份未复核不询问")
        auth.isIdentityVerified = true
        await settle()
        XCTAssertEqual(p.shown.count, 1, "登录并复核后，即使没有列表窗口也会询问")
        XCTAssertEqual(n.ownership, .unlinkedLocal)
    }

    func testStalePromptWhenAccountChangesWhileDialogIsOpenChangesNothing() async throws {
        let n = add("local", owner: StickyNote.unlinkedOwnerMarker)
        signIn("A")
        let p = FakePresenter(); p.queue = [.accept]; p.choice = .skip
        p.beforeReturn = { [unowned self] in self.signIn("B") }   // user switched account behind the dialog
        let c = coordinator(p); await settle()
        XCTAssertEqual(n.ownership, .unlinkedLocal, "过期提示不得把便笺划给另一个账号")
        XCTAssertNotNil(c.lastError)
        XCTAssertTrue(service.ledger.decisions(for: "A").isEmpty && service.ledger.decisions(for: "B").isEmpty)
    }
    // MARK: legacy cloud-traced copy must not duplicate in the cloud (follow-up #2)
    func testSameLegacyNoteCannotBeCopiedTwiceIntoTheSameAccountButCanAfterTheCopyIsGone() throws {
        let legacy = add("legacy-cloud", owner: nil, remote: "R-old"); legacy.webNoteJSON = "{}"
        signIn("A")
        let first = try service.copyLegacyToCurrentAccount(legacy, modelContext: context)
        XCTAssertEqual(try all().filter { $0.ownerAccountID == "A" }.count, 1)
        XCTAssertThrowsError(try service.copyLegacyToCurrentAccount(legacy, modelContext: context)) { error in
            guard case IsolationError.notEligible = error else { return XCTFail("应为硬拒绝: \(error)") }
        }
        XCTAssertThrowsError(try service.copyLegacyToCurrentAccount(legacy, allowSimilarContent: true, modelContext: context),
                             "‘仍然复制’也不能绕过同源重复复制的硬拒绝")
        XCTAssertEqual(try all().filter { $0.ownerAccountID == "A" }.count, 1, "没有产生第二个副本")
        // 另一个账号的范围是独立的
        signIn("B")
        XCTAssertNoThrow(try service.copyLegacyToCurrentAccount(legacy, modelContext: context))
        // 副本被用户删除之后可以再复制
        signIn("A")
        first.isDeletedLocally = true; try context.save()
        XCTAssertNoThrow(try service.copyLegacyToCurrentAccount(legacy, modelContext: context))
        XCTAssertNil(legacy.ownerAccountID, "原件始终留在隔离区")
    }

    func testCopyIsRefusedWhenTheAccountAlreadyHoldsTheSameCloudObject() throws {
        let legacy = add("old text", owner: nil, remote: "R-same")
        add("pulled down from cloud", owner: "A", remote: "R-same")
        signIn("A")
        XCTAssertThrowsError(try service.copyLegacyToCurrentAccount(legacy, allowSimilarContent: true, modelContext: context)) { error in
            guard case IsolationError.notEligible = error else { return XCTFail("\(error)") }
        }
        // a different account (which does not hold R-same) may still copy it
        signIn("B")
        XCTAssertNoThrow(try service.copyLegacyToCurrentAccount(legacy, modelContext: context))
    }

    func testIdenticalTextInTheAccountAsksFirstAndCopiesOnlyWhenConfirmed() throws {
        let legacy = add("  shopping list\n", owner: nil, remote: "R-old")
        add("shopping list", owner: "A", remote: "R-other")
        let unrelated = add("unrelated", owner: nil, remote: "R-x")
        signIn("A")
        let before = try all().count
        XCTAssertThrowsError(try service.copyLegacyToCurrentAccount(legacy, modelContext: context)) { error in
            guard case IsolationError.duplicateRisk = error else { return XCTFail("应为需确认的软拦截: \(error)") }
        }
        XCTAssertEqual(try all().count, before, "未确认前不创建副本")
        XCTAssertNoThrow(try service.copyLegacyToCurrentAccount(unrelated, modelContext: context), "内容不同无需确认")
        let copy = try service.copyLegacyToCurrentAccount(legacy, allowSimilarContent: true, modelContext: context)
        XCTAssertEqual(copy.ownerAccountID, "A"); XCTAssertNil(copy.remoteId)
    }

    func testCopyNeverTalksToTheCloud() async throws {
        let legacy = add("legacy-cloud", owner: nil, remote: "R-old")
        signIn("A")
        MockURLProtocol.handler = { [self] in listReply($0) }
        _ = try service.copyLegacyToCurrentAccount(legacy, modelContext: context)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty, "复制本身只改本地；上传走正常同步")
    }
}

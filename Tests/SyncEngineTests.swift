import XCTest
import SwiftData
import AppKit

/// 模块 4：同步状态机 / 防抖 / 重试边界 / 0x8b00 扩展属性
/// 所有 Graph 请求均由 MockURLProtocol 在本地应答，AuthManager 为测试替身，无真实云端调用。
@MainActor
final class SyncEngineTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    nonisolated private let colorPropId = "Integer {0006200e-0000-0000-c000-000000000046} Id 0x8b00"

    override func setUp() async throws {
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        AuthManager.shared.reset()
        let schema = Schema([StickyNote.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        container = nil
    }

    private func bodyJSON(_ r: MockURLProtocol.Recorded) -> [String: Any]? {
        guard let b = r.body else { return nil }
        return try? JSONSerialization.jsonObject(with: b) as? [String: Any]
    }

    nonisolated private func message(id: String, changeKey: String, html: String, color: Int?, modified: String = "2030-01-01T00:00:00Z") -> [String: Any] {
        var m: [String: Any] = [
            "id": id, "changeKey": changeKey,
            "subject": "s", "body": ["contentType": "html", "content": html],
            "createdDateTime": "2026-01-01T00:00:00Z", "lastModifiedDateTime": modified
        ]
        if let color { m["singleValueExtendedProperties"] = [["id": colorPropId, "value": "\(color)"]] }
        return m
    }

    // MARK: Upload (push)

    func testUploadNewNotePostsWith0x8b00AndBecomesSynced() async throws {
        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "R-1", "changeKey": "CK-1", "body": ["contentType": "html", "content": "<div>Hello<br/>World</div>"]]) }
        let note = StickyNote(color: .green, content: "Hello\nWorld")
        ctx.insert(note)
        XCTAssertEqual(note.syncStatus, .pendingUpload)

        try await SyncEngine().uploadNote(note, token: "t")

        XCTAssertEqual(note.syncStatus, .synced)
        XCTAssertEqual(note.remoteId, "R-1")
        XCTAssertEqual(note.changeKey, "CK-1")
        XCTAssertNotNil(note.lastSyncedAt)

        let req = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.absoluteString, "https://graph.microsoft.com/v1.0/me/notes")
        XCTAssertEqual(req.headers["Authorization"], "Bearer t")
        let body = try XCTUnwrap(bodyJSON(req))
        XCTAssertEqual(body["subject"] as? String, "Hello")
        let props = try XCTUnwrap(body["singleValueExtendedProperties"] as? [[String: Any]])
        XCTAssertEqual(props.first?["id"] as? String, colorPropId)
        XCTAssertEqual(props.first?["value"] as? String, "1", "green -> PidLidNoteColor 1")
        let content = (body["body"] as? [String: Any])?["content"] as? String
        XCTAssertEqual(content, "<div>Hello<br/>World</div>")
    }

    func testUploadExistingNoteUsesPatch() async throws {
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "R-9", "changeKey": "CK-NEW", "body": ["contentType": "html", "content": "<div>x</div>"]]) }
        let note = StickyNote(color: .blue, content: "x", remoteId: "R-9", changeKey: "CK-OLD")
        ctx.insert(note)
        try await SyncEngine().uploadNote(note, token: "t")
        let req = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(req.method, "PATCH")
        XCTAssertEqual(req.url.absoluteString, "https://graph.microsoft.com/v1.0/me/notes/R-9")
        XCTAssertEqual(note.changeKey, "CK-NEW")
        XCTAssertEqual(note.syncStatus, .synced)
        XCTAssertEqual(((bodyJSON(req)?["singleValueExtendedProperties"] as? [[String: Any]])?.first?["value"] as? String), "0")
    }

    func testEmptyNoteUploadUsesNewNoteSubject() async throws {
        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "R-2", "changeKey": "CK"]) }
        let note = StickyNote(content: "")
        ctx.insert(note)
        try await SyncEngine().uploadNote(note, token: "t")
        let body = try XCTUnwrap(bodyJSON(try XCTUnwrap(MockURLProtocol.requests.first)))
        XCTAssertEqual(body["subject"] as? String, "New Note")
        XCTAssertEqual((body["body"] as? [String: Any])?["content"] as? String, "<div></div>")
    }

    func testUploadServerErrorSetsErrorStatusAndThrows() async {
        MockURLProtocol.handler = { _ in .http(status: 500, json: ["error": "boom"]) }
        let note = StickyNote(content: "x")
        ctx.insert(note)
        do {
            try await SyncEngine().uploadNote(note, token: "t")
            XCTFail("应抛错")
        } catch {
            XCTAssertEqual((error as NSError).code, 500)
        }
        XCTAssertEqual(note.syncStatus, .error)
        XCTAssertNil(note.remoteId)
    }

    func testUpload401RefreshesExactlyOnceThenFails() async {
        MockURLProtocol.handler = { _ in .http(status: 401, json: [:]) }
        let note = StickyNote(content: "x")
        ctx.insert(note)
        do { try await SyncEngine().uploadNote(note, token: "t"); XCTFail("应抛错") } catch {}
        XCTAssertEqual(AuthManager.shared.refreshCallCount, 1, "上传 401 只应刷新一次 token")
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertEqual(MockURLProtocol.requests.last?.headers["Authorization"], "Bearer refreshed-token-1")
        XCTAssertEqual(note.syncStatus, .error)
    }

    func testUpload401ThenSuccessAfterRefresh() async throws {
        var calls = 0
        MockURLProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? .http(status: 401, json: [:]) : .http(status: 201, json: ["id": "R-3", "changeKey": "CK"])
        }
        let note = StickyNote(content: "x")
        ctx.insert(note)
        try await SyncEngine().uploadNote(note, token: "t")
        XCTAssertEqual(note.syncStatus, .synced)
        XCTAssertEqual(AuthManager.shared.refreshCallCount, 1)
    }

    func testUploadDoesNotMarkSyncedWhenServerReturnsStaleBody() async {
        MockURLProtocol.handler = { _ in
            .http(status: 200, json: [
                "id": "R-9",
                "changeKey": "CK-NEW",
                "body": ["contentType": "html", "content": "<div>old cloud text</div>"]
            ])
        }
        let note = StickyNote(color: .blue, content: "new local text", remoteId: "R-9", changeKey: "CK-OLD")
        ctx.insert(note)
        do {
            try await SyncEngine().uploadNote(note, token: "t")
            XCTFail("正文未写回时不应视为成功")
        } catch {
            XCTAssertEqual((error as NSError).code, -3)
        }
        XCTAssertEqual(note.syncStatus, .error)
        XCTAssertEqual(note.changeKey, "CK-OLD", "假成功响应不得覆盖本地 changeKey")
        XCTAssertEqual(note.remoteId, "R-9")
        XCTAssertEqual(MockURLProtocol.requests.first?.method, "PATCH")
        XCTAssertEqual(MockURLProtocol.requests.first?.url.absoluteString, "https://graph.microsoft.com/v1.0/me/notes/R-9")
    }

    func testUploadEmpty204IsNotTreatedAsSuccess() async {
        MockURLProtocol.handler = { _ in .http(status: 204, json: nil) }
        let note = StickyNote(content: "edited", remoteId: "R-9", changeKey: "CK-OLD")
        ctx.insert(note)
        do {
            try await SyncEngine().uploadNote(note, token: "t")
            XCTFail("空 204 不应视为已同步")
        } catch {
            XCTAssertEqual((error as NSError).code, -3)
        }
        XCTAssertEqual(note.syncStatus, .error)
    }

    func testUploadFallsBackToRecreateWhenNotesApiForbidden() async throws {
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "PATCH":
                return .http(status: 403, json: ["error": "forbidden"])
            case "POST":
                return .http(status: 201, json: [
                    "id": "R-NEW",
                    "changeKey": "CK2",
                    "body": ["contentType": "html", "content": "<div>x</div>"]
                ])
            case "DELETE":
                return .http(status: 204, json: nil)
            default:
                return .http(status: 500, json: [:])
            }
        }
        let note = StickyNote(content: "x", remoteId: "R-OLD", changeKey: "CK1")
        ctx.insert(note)
        try await SyncEngine().uploadNote(note, token: "t", retryAuthOnFailure: false)
        XCTAssertEqual(note.syncStatus, .synced)
        XCTAssertEqual(note.remoteId, "R-NEW")
        XCTAssertEqual(note.changeKey, "CK2")
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["PATCH", "POST", "DELETE"])
        XCTAssertEqual(MockURLProtocol.requests[0].url.absoluteString, "https://graph.microsoft.com/v1.0/me/notes/R-OLD")
        XCTAssertEqual(MockURLProtocol.requests[1].url.absoluteString, "https://graph.microsoft.com/v1.0/me/mailFolders/notes/messages")
        XCTAssertEqual(MockURLProtocol.requests[2].url.absoluteString, "https://graph.microsoft.com/v1.0/me/messages/R-OLD")
    }

    func testSyncAllDoesNotReportSyncedWhenPushFailsAfterPull() async throws {
        let note = StickyNote(content: "local edit", remoteId: "R-1", changeKey: "OLD", syncStatus: .pendingUpload)
        ctx.insert(note)
        let engine = SyncEngine()
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": []])
            }
            return .http(status: 200, json: ["id": "R-1", "changeKey": "OLD"])
        }
        await engine.syncAll(modelContext: ctx)
        if case .error = engine.state {} else {
            XCTFail("上传假成功时引擎状态仍为 \(engine.state)，UI 会显示已同步")
        }
        XCTAssertEqual(note.syncStatus, .error)
    }

    // MARK: Full sync state machine


    func testSyncAllUnauthenticatedGoesOffline() async {
        AuthManager.shared.isAuthenticated = false
        let engine = SyncEngine()
        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(engine.state, .offline)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testSyncAllPullsNewRemoteNoteWithColorAndPushesPending() async throws {
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [self.message(id: "R-A", changeKey: "K1", html: "<div>From cloud<br>2nd</div>", color: 2)]])
            }
            return .http(status: 201, json: ["id": "R-LOCAL", "changeKey": "K-L"])
        }
        let local = StickyNote(color: .gray, content: "local pending")
        ctx.insert(local)
        try ctx.save()

        let engine = SyncEngine()
        await engine.syncAll(modelContext: ctx)

        XCTAssertEqual(engine.state, .idle)
        XCTAssertNotNil(engine.lastSyncDate)
        let all = try ctx.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(all.count, 2)
        let remote = try XCTUnwrap(all.first { $0.remoteId == "R-A" })
        XCTAssertEqual(remote.noteColor, .pink, "0x8b00=2 -> pink")
        XCTAssertEqual(remote.plainTextContent, "From cloud\n2nd")
        XCTAssertEqual(remote.syncStatus, .synced)
        XCTAssertEqual(local.syncStatus, .synced)
        XCTAssertEqual(local.remoteId, "R-LOCAL")
        let get = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(get.method, "GET")
        XCTAssertTrue(get.url.absoluteString.contains("0x8b00"), "拉取请求应 expand 0x8b00 扩展属性")
    }

    func testSyncAllNetworkDownSetsErrorAndKeepsPending() async throws {
        MockURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        let note = StickyNote(content: "offline edit")
        ctx.insert(note)
        let engine = SyncEngine()
        await engine.syncAll(modelContext: ctx)
        if case .error = engine.state {} else { XCTFail("断网应进入 error 状态，实际 \(engine.state)") }
        XCTAssertEqual(note.syncStatus, .pendingUpload, "断网时本地改动应保留为待上传")
    }

    func testRecoveryAfterNetworkRestored() async throws {
        let note = StickyNote(content: "edit")
        ctx.insert(note)
        let engine = SyncEngine()
        MockURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(note.syncStatus, .pendingUpload)
        MockURLProtocol.handler = { req in
            req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 201, json: ["id": "R", "changeKey": "K"])
        }
        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(note.syncStatus, .synced)
    }

    func testPushFailureMarksErrorAndErrorNotesAreRetriedNextSync() async throws {
        let note = StickyNote(content: "x")
        ctx.insert(note)
        let engine = SyncEngine()
        MockURLProtocol.handler = { req in
            req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .failure(.timedOut)
        }
        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(note.syncStatus, .error)
        MockURLProtocol.handler = { req in
            req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 201, json: ["id": "R", "changeKey": "K"])
        }
        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(note.syncStatus, .synced, "error 状态的便签应在下次同步时重试")
    }

    /// 重试边界：拉取遇到持续 401 时，刷新 token 应有上限（与上传路径一致，最多 1 次）。
    func testPull401RetryIsBounded() async {
        MockURLProtocol.handler = { _ in .http(status: 401, json: [:]) }
        AuthManager.shared.maxRefreshesBeforeThrow = 10
        let engine = SyncEngine()
        await engine.syncAll(modelContext: ctx)
        print("QA_METRIC pull401RefreshCalls=\(AuthManager.shared.refreshCallCount) requests=\(MockURLProtocol.requests.count)")
        XCTAssertLessThanOrEqual(AuthManager.shared.refreshCallCount, 1,
                                 "拉取 401 刷新次数无上限：测试替身在第 \(AuthManager.shared.refreshCallCount) 次时强制中断")
    }

    func testConflictRemoteNewerKeepsLocalCopy() async throws {
        let local = StickyNote(color: .blue, content: "local edit", remoteId: "R-C", changeKey: "OLD", syncStatus: .pendingUpload)
        local.modifiedAt = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        ctx.insert(local)
        try ctx.save()
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [self.message(id: "R-C", changeKey: "NEW", html: "<div>cloud edit</div>", color: 0, modified: "2030-01-01T00:00:00Z")]])
            }
            return .http(status: 201, json: ["id": "R-COPY", "changeKey": "K"])
        }
        let engine = SyncEngine()
        await engine.syncAll(modelContext: ctx)
        let all = try ctx.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(all.count, 2, "冲突时应保留本地副本")
        XCTAssertEqual(local.plainTextContent, "cloud edit")
        XCTAssertEqual(local.changeKey, "NEW")
        XCTAssertTrue(all.contains { $0.plainTextContent == "local edit" }, "本地内容应以副本保留")
    }

    /// 云端修改颜色（0x8b00 变化）后，已存在的本地便签应更新颜色。
    func testRemoteColorChangeAppliedToExistingNote() async throws {
        let local = StickyNote(color: .yellow, content: "same", remoteId: "R-COL", changeKey: "K1", syncStatus: .synced)
        ctx.insert(local)
        try ctx.save()
        MockURLProtocol.handler = { req in
            .http(status: 200, json: ["value": [self.message(id: "R-COL", changeKey: "K2", html: "<div>same</div>", color: 0)]])
        }
        await SyncEngine().syncAll(modelContext: ctx)
        XCTAssertEqual(local.changeKey, "K2")
        XCTAssertEqual(local.noteColor, .blue, "云端改为蓝色(0)，本地仍为 \(local.noteColor)")
    }

    /// 删除后若远端删除失败（断网），下次拉取不应“复活”已删除便签。
    func testDeletedNoteNotResurrectedAfterOfflineDelete() async throws {
        MockURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        let engine = SyncEngine()
        engine.deleteRemoteNote(remoteId: "R-DEL")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.method == "DELETE" }.count, 1)
        // 本地已删除（ctx 中不存在）；网络恢复后云端仍有该消息
        MockURLProtocol.handler = { req in
            .http(status: 200, json: ["value": [self.message(id: "R-DEL", changeKey: "K", html: "<div>deleted</div>", color: 3)]])
        }
        await engine.syncAll(modelContext: ctx)
        let count = try ctx.fetchCount(FetchDescriptor<StickyNote>())
        XCTAssertEqual(count, 0, "已删除便签在下次同步时被重新拉回（无删除墓碑/重试队列）")
    }

    /// 远端 DELETE 返回非 2xx 时应有错误反馈或重试（当前代码忽略响应码）。
    func testDeleteRemoteHttpErrorIsNotSilentlyIgnored() async throws {
        MockURLProtocol.handler = { _ in .http(status: 500, json: [:]) }
        let engine = SyncEngine()
        engine.deleteRemoteNote(remoteId: "R-X")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        if case .error = engine.state {} else {
            XCTFail("DELETE 返回 500 后引擎状态仍为 \(engine.state)，失败被静默吞掉")
        }
    }

    // MARK: Debounce

    func testDebounceCoalescesRapidEditsIntoOneUpload() async throws {
        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "R-D", "changeKey": "K"]) }
        let note = StickyNote(content: "typing")
        ctx.insert(note)
        try ctx.save()
        let engine = SyncEngine()
        for _ in 0..<5 {
            engine.scheduleDebouncedPush(for: note.id, in: ctx)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(MockURLProtocol.requests.count, 0, "防抖窗口内不应上传")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(MockURLProtocol.requests.count, 1, "5 次快速编辑应合并为 1 次上传")
        XCTAssertEqual(note.syncStatus, .synced)
    }

    func testDebounceSkippedWhenNotAuthenticated() async throws {
        AuthManager.shared.isAuthenticated = false
        let note = StickyNote(content: "x")
        ctx.insert(note)
        let engine = SyncEngine()
        engine.scheduleDebouncedPush(for: note.id, in: ctx)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        XCTAssertEqual(note.syncStatus, .pendingUpload)
    }

    func testDebouncedPushNetworkErrorSetsError() async throws {
        MockURLProtocol.handler = { _ in .failure(.networkConnectionLost) }
        let note = StickyNote(content: "x")
        ctx.insert(note)
        try ctx.save()
        let engine = SyncEngine()
        engine.scheduleDebouncedPush(for: note.id, in: ctx)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(note.syncStatus, .error)
        XCTAssertEqual(MockURLProtocol.requests.count, 1, "防抖上传失败后无自动重试（仅依赖下次全量同步）")
    }

    // MARK: Sort / timestamps

    func testPullRequestOrdersByLastModifiedDateTimeDescending() async {
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["value": []]) }
        await SyncEngine().syncAll(modelContext: ctx)
        let get = try! XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertTrue(get.url.absoluteString.contains("orderby=lastModifiedDateTime"), "拉取应按 lastModifiedDateTime 降序请求")
    }

    func testLocalCreateStaysOnTopAfterPullWithStaleRemoteTimestamp() async throws {
        let localCreated = Date()
        let note = StickyNote(content: "just created")
        note.modifiedAt = localCreated
        note.remoteId = "R-NEW"
        note.changeKey = "CK-LOCAL"
        note.syncStatus = .synced
        ctx.insert(note)
        let older = StickyNote(content: "older cloud")
        older.remoteId = "R-OLD"
        older.changeKey = "K-OLD"
        older.syncStatus = .synced
        older.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        ctx.insert(older)
        try ctx.save()

        MockURLProtocol.handler = { req in
            .http(status: 200, json: ["value": [
                self.message(id: "R-OLD", changeKey: "K-OLD", html: "<div>older cloud</div>", color: 3, modified: "2023-12-01T00:00:00Z"),
                self.message(id: "R-NEW", changeKey: "CK-REMOTE", html: "<div>just created</div>", color: 3, modified: "0001-01-01T00:00:00Z")
            ]])
        }
        await SyncEngine().syncAll(modelContext: ctx)
        XCTAssertEqual(note.changeKey, "CK-REMOTE")
        XCTAssertEqual(note.plainTextContent, "just created")
        XCTAssertGreaterThan(note.modifiedAt, older.modifiedAt, "无效/默认的远端时间戳不得把本地新建便签沉底")
        let ranked = StickyNote.visibleNewestFirst(try ctx.fetch(FetchDescriptor<StickyNote>()))
        XCTAssertEqual(ranked.first?.remoteId, "R-NEW")
    }

    func testPulledNotesSortByLastModifiedDescending() async throws {
        MockURLProtocol.handler = { req in
            .http(status: 200, json: ["value": [
                self.message(id: "R-OLD", changeKey: "1", html: "<div>old</div>", color: 3, modified: "2024-01-01T00:00:00Z"),
                self.message(id: "R-MID", changeKey: "2", html: "<div>mid</div>", color: 3, modified: "2025-06-01T00:00:00Z"),
                self.message(id: "R-NEW", changeKey: "3", html: "<div>new</div>", color: 3, modified: "2026-11-01T00:00:00Z")
            ]])
        }
        await SyncEngine().syncAll(modelContext: ctx)
        let ranked = StickyNote.visibleNewestFirst(try ctx.fetch(FetchDescriptor<StickyNote>()))
        XCTAssertEqual(ranked.map(\.remoteId), ["R-NEW", "R-MID", "R-OLD"])
    }

    func testMailFolderFallbackSendsStickyNoteClassAndCurrentTimestamps() async throws {
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "POST" where req.url?.absoluteString.contains("me/notes") == true && req.url?.absoluteString.contains("mailFolders") != true:
                return .http(status: 403, json: ["error": "forbidden"])
            case "POST":
                return .http(status: 201, json: [
                    "id": "R-MAIL",
                    "changeKey": "CK-MAIL",
                    "createdDateTime": "2026-11-06T00:00:00Z",
                    "lastModifiedDateTime": "2026-11-06T00:00:00Z"
                ])
            default:
                return .http(status: 500, json: [:])
            }
        }
        let note = StickyNote(content: "fresh")
        note.modifiedAt = Date()
        ctx.insert(note)
        try await SyncEngine().uploadNote(note, token: "t", retryAuthOnFailure: false)
        XCTAssertEqual(note.syncStatus, .synced)
        XCTAssertEqual(note.remoteId, "R-MAIL")
        let post = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(post.url.absoluteString, "https://graph.microsoft.com/v1.0/me/mailFolders/notes/messages")
        let body = try XCTUnwrap(bodyJSON(post))
        let props = try XCTUnwrap(body["singleValueExtendedProperties"] as? [[String: Any]])
        XCTAssertTrue(props.contains { ($0["value"] as? String) == "IPM.StickyNote" })
        XCTAssertNotNil(body["receivedDateTime"] as? String)
        XCTAssertNotNil(body["sentDateTime"] as? String)
        XCTAssertGreaterThanOrEqual(note.modifiedAt, SyncEngine.parseGraphDate("2026-11-06T00:00:00Z")!)
    }

    func testParseGraphDateAcceptsLongFractionalSecondsAndRejectsSentinel() {
        XCTAssertNotNil(SyncEngine.parseGraphDate("2026-11-06T08:32:15.1234567Z"))
        XCTAssertNotNil(SyncEngine.parseGraphDate("2026-11-06T08:32:15Z"))
        XCTAssertNil(SyncEngine.plausibleGraphDate("0001-01-01T00:00:00Z"))
        XCTAssertNil(SyncEngine.plausibleGraphDate("not-a-date"))
        XCTAssertNotNil(SyncEngine.plausibleGraphDate("2026-01-01T00:00:00Z"))
    }
}

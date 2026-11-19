import XCTest
import SwiftData
import AppKit

/// 模块 4：同步状态机 / 防抖 / 重试边界 / 0x8b00 扩展属性
/// 所有 Graph 请求均由 MockURLProtocol 在本地应答，AuthManager 为测试替身，无真实云端调用。
@MainActor
final class SyncEngineTests: XCTestCase {

    private var container: ModelContainer!
    private var ledgerSuites: [String] = []
    private var ctx: ModelContext { container.mainContext }
    nonisolated private let colorPropId = "Integer {0006200e-0000-0000-c000-000000000046} Id 0x8b00"
    nonisolated private let webNotePropId = "String {00020329-0000-0000-c000-000000000046} Name _Note"

    override func setUp() async throws {
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        SyncAuthStub.shared.reset()
        let schema = Schema([StickyNote.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        for name in ledgerSuites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        ledgerSuites = []
        container = nil
    }

    private func insertOwned(_ note: StickyNote) {
        note.ownerAccountID = "test-account"
        ctx.insert(note)
    }

    private func bodyJSON(_ r: MockURLProtocol.Recorded) -> [String: Any]? {
        guard let b = r.body else { return nil }
        return try? JSONSerialization.jsonObject(with: b) as? [String: Any]
    }

    private func propValue(_ props: [[String: Any]], id: String) -> String? {
        props.first { ($0["id"] as? String) == id }?["value"] as? String
    }

    private func assertWebNoteColor(_ props: [[String: Any]], expected: Int) throws {
        let json = try XCTUnwrap(self.propValue(props, id: self.webNotePropId), "请求体缺少网页端 _Note JSON")
        let data = try XCTUnwrap(json.data(using: .utf8))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["color"] as? Int, expected, "网页端 _Note.color 应为 \(expected)")
    }


    nonisolated private func message(id: String, changeKey: String, html: String, color: Int?, modified: String = "2030-01-01T00:00:00Z") -> [String: Any] {
        var m: [String: Any] = [
            "id": id, "changeKey": changeKey,
            "subject": "s", "body": ["contentType": "html", "content": html],
            "createdDateTime": "2026-01-01T00:00:00Z", "lastModifiedDateTime": modified
        ]
        if let color {
            let webColor = NoteConverter.noteColor(fromWebCode: color)
            let lid = NoteConverter.pidLidNoteColorCode(for: webColor)
            m["singleValueExtendedProperties"] = [
                ["id": colorPropId, "value": "\(lid)"],
                ["id": webNotePropId, "value": "{\"color\":\(color),\"#type.color\":\"Int32\"}"]
            ]
        }
        return m
    }

    // MARK: Upload (push)

    func testUploadNewNotePostsWith0x8b00AndBecomesSynced() async throws {
        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "R-1", "changeKey": "CK-1", "body": ["contentType": "html", "content": "<div>Hello<br/>World</div>"]]) }
        let note = StickyNote(color: .green, content: "Hello\nWorld")
        insertOwned(note)
        XCTAssertEqual(note.syncStatus, .pendingUpload)

        try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t")

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
        XCTAssertEqual(self.propValue(props, id: self.colorPropId), "1", "green -> PidLidNoteColor 1")
        try self.assertWebNoteColor(props, expected: 1)
        let content = (body["body"] as? [String: Any])?["content"] as? String
        XCTAssertEqual(content, "<div>Hello<br/>World</div>")
    }

    func testUploadExistingNoteUsesPatch() async throws {
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "R-9", "changeKey": "CK-NEW", "body": ["contentType": "html", "content": "<div>x</div>"]]) }
        let note = StickyNote(color: .blue, content: "x", remoteId: "R-9", changeKey: "CK-OLD")
        insertOwned(note)
        let ledger = isolatedLedger(); ledger.markDirty(note.id)   // 用户在本地选过颜色 → 才会写颜色属性
        try await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger).uploadNote(note, token: "t")
        let req = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(req.method, "PATCH")
        XCTAssertEqual(req.url.absoluteString, "https://graph.microsoft.com/v1.0/me/notes/R-9")
        XCTAssertEqual(note.changeKey, "CK-NEW")
        XCTAssertEqual(note.syncStatus, .synced)
        let props = try XCTUnwrap(bodyJSON(req)?["singleValueExtendedProperties"] as? [[String: Any]])
        XCTAssertEqual(self.propValue(props, id: self.colorPropId), "0", "blue -> PidLidNoteColor 0 (classic)")
        try self.assertWebNoteColor(props, expected: 4)
    }

    func testEmptyNoteUploadUsesNewNoteSubject() async throws {
        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "R-2", "changeKey": "CK"]) }
        let note = StickyNote(content: "")
        insertOwned(note)
        try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t")
        let body = try XCTUnwrap(bodyJSON(try XCTUnwrap(MockURLProtocol.requests.first)))
        XCTAssertEqual(body["subject"] as? String, "New Note")
        XCTAssertEqual((body["body"] as? [String: Any])?["content"] as? String, "<div></div>")
    }

    func testUploadServerErrorSetsErrorStatusAndThrows() async {
        MockURLProtocol.handler = { _ in .http(status: 500, json: ["error": "boom"]) }
        let note = StickyNote(content: "x")
        insertOwned(note)
        do {
            try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t")
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
        insertOwned(note)
        do { try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t"); XCTFail("应抛错") } catch {}
        XCTAssertEqual(SyncAuthStub.shared.refreshCallCount, 1, "上传 401 只应刷新一次 token")
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
        insertOwned(note)
        try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t")
        XCTAssertEqual(note.syncStatus, .synced)
        XCTAssertEqual(SyncAuthStub.shared.refreshCallCount, 1)
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
        insertOwned(note)
        do {
            try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t")
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
        insertOwned(note)
        do {
            try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t")
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
        insertOwned(note)
        try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t", retryAuthOnFailure: false)
        XCTAssertEqual(note.syncStatus, .synced)
        XCTAssertEqual(note.remoteId, "R-NEW")
        XCTAssertEqual(note.changeKey, "CK2")
        // 颜色未被用户改过 → 先只读取旧对象的原始颜色属性（此处 handler 对 GET 回 500 = 读取失败，不会瞎猜颜色）
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["PATCH", "GET", "POST", "DELETE"])
        XCTAssertEqual(MockURLProtocol.requests[0].url.absoluteString, "https://graph.microsoft.com/v1.0/me/notes/R-OLD")
        XCTAssertTrue(MockURLProtocol.requests[1].url.absoluteString.hasPrefix("https://graph.microsoft.com/v1.0/me/messages/R-OLD?"))
        XCTAssertEqual(MockURLProtocol.requests[2].url.absoluteString, "https://graph.microsoft.com/v1.0/me/mailFolders/notes/messages")
        XCTAssertEqual(MockURLProtocol.requests[3].url.absoluteString, "https://graph.microsoft.com/v1.0/me/messages/R-OLD")
    }

    func testSyncAllDoesNotReportSyncedWhenPushFailsAfterPull() async throws {
        let note = StickyNote(content: "local edit", remoteId: "R-1", changeKey: "OLD", syncStatus: .pendingUpload)
        insertOwned(note)
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
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
        SyncAuthStub.shared.isAuthenticated = false
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
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
        insertOwned(local)
        try ctx.save()

        let engine = SyncEngine(authManager: SyncAuthStub.shared)
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
        XCTAssertTrue(get.url.absoluteString.contains("_Note") || get.url.absoluteString.contains("%5FNote") || get.url.absoluteString.lowercased().contains("name%20_note") || get.url.absoluteString.contains("Name%20_Note"), "拉取请求应 expand 网页端 _Note JSON")
    }

    func testSyncAllNetworkDownSetsErrorAndKeepsPending() async throws {
        MockURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        let note = StickyNote(content: "offline edit")
        insertOwned(note)
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        await engine.syncAll(modelContext: ctx)
        if case .error = engine.state {} else { XCTFail("断网应进入 error 状态，实际 \(engine.state)") }
        XCTAssertEqual(note.syncStatus, .pendingUpload, "断网时本地改动应保留为待上传")
    }

    func testRecoveryAfterNetworkRestored() async throws {
        let note = StickyNote(content: "edit")
        insertOwned(note)
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
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
        let note = StickyNote(content: "x", remoteId: "known-id", changeKey: "old")
        insertOwned(note)
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        MockURLProtocol.handler = { req in
            req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .failure(.timedOut)
        }
        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(note.syncStatus, .error)
        MockURLProtocol.handler = { req in
            req.httpMethod == "GET" ? .http(status: 200, json: ["value": []]) : .http(status: 200, json: ["id": "known-id", "changeKey": "K", "body": ["content": "<div>x</div>"]])
        }
        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(note.syncStatus, .synced, "error 状态的便签应在下次同步时重试")
    }

    /// 重试边界：拉取遇到持续 401 时，刷新 token 应有上限（与上传路径一致，最多 1 次）。
    func testPull401RetryIsBounded() async {
        MockURLProtocol.handler = { _ in .http(status: 401, json: [:]) }
        SyncAuthStub.shared.maxRefreshesBeforeThrow = 10
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        await engine.syncAll(modelContext: ctx)
        print("QA_METRIC pull401RefreshCalls=\(SyncAuthStub.shared.refreshCallCount) requests=\(MockURLProtocol.requests.count)")
        XCTAssertLessThanOrEqual(SyncAuthStub.shared.refreshCallCount, 1,
                                 "拉取 401 刷新次数无上限：测试替身在第 \(SyncAuthStub.shared.refreshCallCount) 次时强制中断")
    }

    func testConflictRemoteNewerKeepsLocalCopy() async throws {
        let local = StickyNote(color: .blue, content: "local edit", remoteId: "R-C", changeKey: "OLD", syncStatus: .pendingUpload)
        local.modifiedAt = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        insertOwned(local)
        try ctx.save()
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [self.message(id: "R-C", changeKey: "NEW", html: "<div>cloud edit</div>", color: 0, modified: "2030-01-01T00:00:00Z")]])
            }
            return .http(status: 201, json: ["id": "R-COPY", "changeKey": "K"])
        }
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
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
        insertOwned(local)
        try ctx.save()
        MockURLProtocol.handler = { req in
            .http(status: 200, json: ["value": [self.message(id: "R-COL", changeKey: "K2", html: "<div>same</div>", color: 4)]])
        }
        await SyncEngine(authManager: SyncAuthStub.shared).syncAll(modelContext: ctx)
        XCTAssertEqual(local.changeKey, "K2")
        XCTAssertEqual(local.noteColor, .blue, "云端改为蓝色(4)，本地仍为 \(local.noteColor)")
    }

    /// 删除后若远端删除失败（断网），下次拉取不应“复活”已删除便签。
    func testDeletedNoteNotResurrectedAfterOfflineDelete() async throws {
        MockURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        engine.deleteRemoteNote(remoteId: "R-DEL", ownerAccountID: "test-account")
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
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        engine.deleteRemoteNote(remoteId: "R-X", ownerAccountID: "test-account")
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
        insertOwned(note)
        try ctx.save()
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
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
        SyncAuthStub.shared.isAuthenticated = false
        let note = StickyNote(content: "x")
        insertOwned(note)
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        engine.scheduleDebouncedPush(for: note.id, in: ctx)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        XCTAssertEqual(note.syncStatus, .pendingUpload)
    }

    func testDebouncedPushNetworkErrorSetsError() async throws {
        MockURLProtocol.handler = { _ in .failure(.networkConnectionLost) }
        let note = StickyNote(content: "x")
        insertOwned(note)
        try ctx.save()
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        engine.scheduleDebouncedPush(for: note.id, in: ctx)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(note.syncStatus, .error)
        XCTAssertEqual(MockURLProtocol.requests.count, 1, "防抖上传失败后无自动重试（仅依赖下次全量同步）")
    }

    // MARK: Sort / timestamps

    func testPullRequestOrdersByLastModifiedDateTimeDescending() async {
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["value": []]) }
        await SyncEngine(authManager: SyncAuthStub.shared).syncAll(modelContext: ctx)
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
        insertOwned(note)
        let older = StickyNote(content: "older cloud")
        older.remoteId = "R-OLD"
        older.changeKey = "K-OLD"
        older.syncStatus = .synced
        older.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        insertOwned(older)
        try ctx.save()

        MockURLProtocol.handler = { req in
            .http(status: 200, json: ["value": [
                self.message(id: "R-OLD", changeKey: "K-OLD", html: "<div>older cloud</div>", color: 3, modified: "2023-12-01T00:00:00Z"),
                self.message(id: "R-NEW", changeKey: "CK-REMOTE", html: "<div>just created</div>", color: 3, modified: "0001-01-01T00:00:00Z")
            ]])
        }
        await SyncEngine(authManager: SyncAuthStub.shared).syncAll(modelContext: ctx)
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
        await SyncEngine(authManager: SyncAuthStub.shared).syncAll(modelContext: ctx)
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
        insertOwned(note)
        try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t", retryAuthOnFailure: false)
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


    func testUploadWritesWebNoteJSONColorForAllOfficialColors() async throws {
        let expected: [(NoteColor, Int)] = [
            (.yellow, 0), (.green, 1), (.pink, 2), (.purple, 3),
            (.blue, 4), (.gray, 5), (.charcoal, 6)
        ]
        for (color, code) in expected {
            MockURLProtocol.reset()
            MockURLProtocol.handler = { _ in
                .http(status: 201, json: [
                    "id": "R-\(color.rawValue)",
                    "changeKey": "CK",
                    "body": ["contentType": "html", "content": "<div>swatch</div>"]
                ])
            }
            let note = StickyNote(color: color, content: "swatch")
            insertOwned(note)
            try await SyncEngine(authManager: SyncAuthStub.shared).uploadNote(note, token: "t")
            let req = try XCTUnwrap(MockURLProtocol.requests.first)
            XCTAssertEqual(req.method, "POST")
            let props = try XCTUnwrap(self.bodyJSON(req)?["singleValueExtendedProperties"] as? [[String: Any]])
            let lid = NoteConverter.pidLidNoteColorCode(for: color)
            XCTAssertEqual(self.propValue(props, id: self.colorPropId), "\(lid)", "\(color.rawValue) PidLid")
            try self.assertWebNoteColor(props, expected: code)
        }
    }

    func testPullPrefersWebNoteJSONColorOverPidLid() async throws {
        MockURLProtocol.handler = { _ in
            .http(status: 200, json: [
                "value": [[
                    "id": "R-WEB",
                    "changeKey": "K1",
                    "subject": "s",
                    "body": ["contentType": "html", "content": "<div>web color</div>"],
                    "createdDateTime": "2026-01-01T00:00:00Z",
                    "lastModifiedDateTime": "2030-01-01T00:00:00Z",
                    "singleValueExtendedProperties": [
                        ["id": self.colorPropId, "value": "0"],
                        ["id": self.webNotePropId, "value": "{\"color\":6,\"#type.color\":\"Int32\"}"]
                    ]
                ]]
            ])
        }
        await SyncEngine(authManager: SyncAuthStub.shared).syncAll(modelContext: ctx)
        let notes = ((try? ctx.fetch(FetchDescriptor<StickyNote>())) ?? [])
        let remote = try XCTUnwrap(notes.first { $0.remoteId == "R-WEB" })
        XCTAssertEqual(remote.noteColor, .charcoal, "网页 _Note.color=6 应覆盖 0x8B00=0")
    }

    func testUploadMergesColorIntoExistingWebNoteJSONDocument() async throws {
        MockURLProtocol.handler = { _ in
            .http(status: 200, json: [
                "id": "R-9",
                "changeKey": "CK-NEW",
                "body": ["contentType": "html", "content": "<div>keep</div>"]
            ])
        }
        let note = StickyNote(color: .purple, content: "keep", remoteId: "R-9", changeKey: "CK-OLD")
        note.webNoteJSON = "{\"schemaVersion\":\"beta\",\"document\":{\"type\":\"document\"},\"color\":0}"
        insertOwned(note)
        let ledger = isolatedLedger(); ledger.markDirty(note.id)
        try await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger).uploadNote(note, token: "t")
        let req = try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "PATCH" })
        let props = try XCTUnwrap(self.bodyJSON(req)?["singleValueExtendedProperties"] as? [[String: Any]])
        try self.assertWebNoteColor(props, expected: 3)
        let json = try XCTUnwrap(self.propValue(props, id: self.webNotePropId))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let document = try XCTUnwrap(obj["document"] as? [String: Any])
        XCTAssertEqual(document["type"] as? String, "document", "改色不得覆盖网页端 document")
    }

    func testParseGraphDateAcceptsLongFractionalSecondsAndRejectsSentinel() {
        XCTAssertNotNil(SyncEngine.parseGraphDate("2026-11-06T08:32:15.1234567Z"))
        XCTAssertNotNil(SyncEngine.parseGraphDate("2026-11-06T08:32:15Z"))
        XCTAssertNil(SyncEngine.plausibleGraphDate("0001-01-01T00:00:00Z"))
        XCTAssertNil(SyncEngine.plausibleGraphDate("not-a-date"))
        XCTAssertNotNil(SyncEngine.plausibleGraphDate("2026-01-01T00:00:00Z"))
    }

    // MARK: Account isolation
    func testOtherAccountAndUnownedUploadsAreRejectedBeforeNetwork() async throws {
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        for owner in ["other-account", nil] as [String?] {
            let note = StickyNote(content: "private", remoteId: "same-remote-id", ownerAccountID: owner)
            note.webNoteJSON = "{\"document\":\"private\"}"
            ctx.insert(note)
            do { try await engine.uploadNote(note, token: "fake-B"); XCTFail("不得跨账号上传") } catch {
                XCTAssertEqual((error as NSError).code, -21)
            }
            XCTAssertEqual(note.remoteId, "same-remote-id")
            XCTAssertEqual(note.plainTextContent, "private")
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testPullSameRemoteIDFromBDoesNotOverwriteAOrLegacyNote() async throws {
        let a = StickyNote(content: "A-private", remoteId: "collision", ownerAccountID: "A", syncStatus: .pendingUpload)
        let legacy = StickyNote(content: "legacy-private", remoteId: "collision", syncStatus: .pendingUpload)
        ctx.insert(a); ctx.insert(legacy)
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["value": [self.message(id: "collision", changeKey: "B-key", html: "<div>B-cloud</div>", color: 1)]]) }
        await SyncEngine(authManager: SyncAuthStub.shared).syncAll(modelContext: ctx)
        XCTAssertEqual(a.plainTextContent, "A-private")
        XCTAssertEqual(legacy.plainTextContent, "legacy-private")
        let all = try ctx.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.contains { $0.ownerAccountID == "test-account" && $0.plainTextContent == "B-cloud" })
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET"])
    }

    func testTombstoneAndQueuedDeleteFromAAreNotSentToB() async throws {
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        MockURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        engine.deleteRemoteNote(remoteId: "A-delete", ownerAccountID: "test-account")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        MockURLProtocol.reset()
        SyncAuthStub.shared.accountID = "B"
        SyncAuthStub.shared.sessionGeneration = UUID()
        let tombstone = StickyNote(content: "A", remoteId: "A-tomb", ownerAccountID: "test-account")
        tombstone.isDeletedLocally = true
        ctx.insert(tombstone)
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["value": []]) }
        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<StickyNote>()), 1)
    }

    func testForeignAndUnknownImmediateDeleteNeverRequestsRemote() async throws {
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        engine.deleteRemoteNote(remoteId: "A-delete", ownerAccountID: "A")
        engine.deleteRemoteNote(remoteId: "legacy-delete", ownerAccountID: nil)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testSwitchDuringPullDiscardsResponseAndDoesNotPush() async throws {
        let note = StickyNote(content: "A-edit", ownerAccountID: "test-account")
        ctx.insert(note)
        MockURLProtocol.responseDelay = 0.15
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["value": [self.message(id: "A-cloud", changeKey: "K", html: "<div>A-cloud</div>", color: 1)]]) }
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        let task = Task { await engine.syncAll(modelContext: ctx) }
        for _ in 0..<100 {
            if !MockURLProtocol.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        SyncAuthStub.shared.accountID = "B"
        SyncAuthStub.shared.sessionGeneration = UUID()
        await task.value
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["GET"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<StickyNote>()), 1)
        XCTAssertNil(note.remoteId)
    }

    func testSwitchDuringUploadCannotApplyOldResponseOrFallback() async throws {
        let note = StickyNote(content: "A-edit", remoteId: "A-id", ownerAccountID: "test-account")
        ctx.insert(note)
        MockURLProtocol.responseDelay = 0.15
        MockURLProtocol.handler = { _ in .http(status: 403, json: [:]) }
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        let task = Task { try await engine.uploadNote(note, token: "fake-A") }
        for _ in 0..<100 {
            if !MockURLProtocol.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        SyncAuthStub.shared.accountID = "B"
        SyncAuthStub.shared.sessionGeneration = UUID()
        do { try await task.value; XCTFail("旧会话应中断") } catch {}
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["PATCH"])
        XCTAssertEqual(SyncAuthStub.shared.refreshCallCount, 0)
        XCTAssertEqual(note.remoteId, "A-id")
    }

    func testOldDebounceCannotUseNewAccountSession() async throws {
        let note = StickyNote(content: "A-edit", ownerAccountID: "test-account")
        ctx.insert(note)
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        engine.scheduleDebouncedPush(for: note.id, in: ctx)
        SyncAuthStub.shared.accountID = "B"
        SyncAuthStub.shared.sessionGeneration = UUID()
        try await Task.sleep(nanoseconds: 1_650_000_000)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        XCTAssertNil(note.remoteId)
    }

    func testLastSyncTimestampIsAccountScoped() {
        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        SyncAuthStub.shared.accountID = UUID().uuidString
        engine.lastSyncDate = Date(timeIntervalSince1970: 1234)
        SyncAuthStub.shared.accountID = UUID().uuidString
        XCTAssertNil(engine.lastSyncDate)
    }

    // MARK: - 网页原色保护（只有用户在本地真的改过颜色才写颜色属性）

    private func isolatedLedger() -> ColorEditLedger {
        let name = "color-ledger-" + UUID().uuidString
        ledgerSuites.append(name)
        return ColorEditLedger(defaults: UserDefaults(suiteName: name)!)
    }

    nonisolated private func colourProps(_ body: [String: Any]?) -> [[String: Any]] {
        (body?["singleValueExtendedProperties"] as? [[String: Any]]) ?? []
    }
    nonisolated private func colourOnly(_ props: [[String: Any]]) -> [[String: Any]] {
        props.filter { ($0["id"] as? String).map { NoteConverter.isPidLidNoteColorProperty($0) || NoteConverter.isWebNoteJSONProperty($0) || NoteConverter.isPidTagIconIndexProperty($0) } ?? false }
    }

    func testPatchWithoutLocalColourChangeSendsNoColourPropertiesAndKeepsTheCachedWebJSON() async throws {
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "R-9", "changeKey": "CK2", "body": ["content": "<div>edited</div>"]]) }
        let note = StickyNote(color: .blue, content: "edited", remoteId: "R-9", changeKey: "CK1")
        note.webNoteJSON = "{\"color\":5,\"document\":{}}"
        insertOwned(note)
        let ledger = isolatedLedger()
        try await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger).uploadNote(note, token: "t")
        let req = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(req.method, "PATCH")
        XCTAssertNil(bodyJSON(req)?["singleValueExtendedProperties"], "没改过颜色：PATCH 里一个颜色属性都不能有（_Note 和 0x8B00 都不写）")
        XCTAssertEqual(note.webNoteJSON, "{\"color\":5,\"document\":{}}", "没写过的颜色不能缓存成已上传")
        XCTAssertEqual(note.syncStatus, .synced)
    }

    func testPatchAfterAnExplicitColourPickWritesBothPropertiesOnceThenIsNoLongerDirty() async throws {
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "R-9", "changeKey": "CK2", "body": ["content": "<div>x</div>"]]) }
        let note = StickyNote(color: .yellow, content: "x", remoteId: "R-9", changeKey: "CK1")
        insertOwned(note)
        let ledger = isolatedLedger()
        note.setColor(.pink, ledger: ledger)
        XCTAssertTrue(ledger.isDirty(note.id))
        let engine = SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger)
        try await engine.uploadNote(note, token: "t")
        let props = colourProps(bodyJSON(try XCTUnwrap(MockURLProtocol.requests.first)))
        XCTAssertEqual(propValue(props, id: colorPropId), "2", "pink → 0x8B00=2")
        try assertWebNoteColor(props, expected: 2)
        XCTAssertFalse(ledger.isDirty(note.id), "颜色已送达后不再脏")
        // 之后只改文字：不再写颜色
        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "R-9", "changeKey": "CK3", "body": ["content": "<div>y</div>"]]) }
        note.plainTextContent = "y"; note.attributedContentData = nil; note.modifiedAt = Date(); note.syncStatus = .pendingUpload
        try await engine.uploadNote(note, token: "t")
        XCTAssertTrue(colourProps(bodyJSON(try XCTUnwrap(MockURLProtocol.requests.first))).isEmpty)
    }

    func testCloudOnlyHas0x8B00AndALaterTextEditNeverBackfillsAnInferredNoteJSON() async throws {
        let ledger = isolatedLedger()
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [[
                    "id": "R-LID", "changeKey": "K1", "subject": "s",
                    "body": ["contentType": "html", "content": "<div>old</div>"],
                    "createdDateTime": "2026-01-01T00:00:00Z", "lastModifiedDateTime": "2026-01-02T00:00:00Z",
                    "singleValueExtendedProperties": [["id": self.colorPropId, "value": "0"]]
                ]]])
            }
            return .http(status: 200, json: ["id": "R-LID", "changeKey": "K2", "body": ["content": "<div>new text</div>"]])
        }
        let engine = SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger)
        await engine.syncAll(modelContext: ctx)
        let note = try XCTUnwrap(try ctx.fetch(FetchDescriptor<StickyNote>()).first { $0.remoteId == "R-LID" })
        XCTAssertEqual(note.noteColor, .blue, "解码策略本轮不变：只有 0x8B00=0 时仍解成蓝")
        XCTAssertNil(note.webNoteJSON)
        XCTAssertFalse(ledger.isDirty(note.id), "从云端拉下来的便笺不是脏的")
        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in .http(status: 200, json: ["id": "R-LID", "changeKey": "K2", "body": ["content": "<div>new text</div>"]]) }
        note.plainTextContent = "new text"; note.attributedContentData = nil; note.modifiedAt = Date(); note.syncStatus = .pendingUpload
        try await engine.uploadNote(note, token: "t")
        let req = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(req.method, "PATCH")
        XCTAssertNil(bodyJSON(req)?["singleValueExtendedProperties"], "不得用本地推断色补写 _Note")
        XCTAssertNil(note.webNoteJSON)
    }

    func testReplaceFallbackCarriesTheOldObjectsOwnColourPropertiesVerbatimNotTheLocalColour() async throws {
        let serverWeb = "{\"schemaVersion\":\"beta\",\"color\":5,\"document\":{\"type\":\"document\"}}"
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "PATCH": return .http(status: 403, json: [:])
            case "GET": return .http(status: 200, json: ["id": "R-OLD", "singleValueExtendedProperties": [
                ["id": "Integer {0006200E-0000-0000-C000-000000000046} Id 0x8B00", "value": "4"],
                ["id": "String {00020329-0000-0000-C000-000000000046} Name _Note", "value": serverWeb]]])
            case "POST": return .http(status: 201, json: ["id": "R-NEW", "changeKey": "CK2", "body": ["content": "<div>x</div>"]])
            default: return .http(status: 204, json: nil)
            }
        }
        let note = StickyNote(color: .yellow, content: "x", remoteId: "R-OLD", changeKey: "CK1")   // 本地"黄"可能是误解码
        insertOwned(note)
        let ledger = isolatedLedger()
        try await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger).uploadNote(note, token: "t", retryAuthOnFailure: false)
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["PATCH", "GET", "POST", "DELETE"])
        let get = MockURLProtocol.requests[1]
        XCTAssertTrue(get.url.absoluteString.contains("0x8b00") && get.url.absoluteString.contains("_Note"), "只读取两个颜色属性")
        let post = MockURLProtocol.requests[2]
        let colours = colourOnly(colourProps(bodyJSON(post)))
        XCTAssertEqual(colours.count, 2)
        XCTAssertEqual(propValue(colours, id: colorPropId), "4", "0x8B00 原值搬运")
        XCTAssertEqual(propValue(colours, id: webNotePropId), serverWeb, "_Note 原文逐字搬运（不合并、不改 color）")
        XCTAssertEqual(note.webNoteJSON, serverWeb)
        XCTAssertEqual(note.remoteId, "R-NEW")
        XCTAssertFalse(ledger.isDirty(note.id))
    }

    func testReplaceFallbackSendsNoColourWhenTheOldObjectHasNone() async throws {
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "PATCH": return .http(status: 400, json: [:])
            case "GET": return .http(status: 200, json: ["id": "R-OLD", "singleValueExtendedProperties": []])
            case "POST": return .http(status: 201, json: ["id": "R-NEW", "changeKey": "CK2", "body": ["content": "<div>x</div>"]])
            default: return .http(status: 204, json: nil)
            }
        }
        let note = StickyNote(color: .green, content: "x", remoteId: "R-OLD", changeKey: "CK1")
        note.webNoteJSON = "{\"color\":1}"
        insertOwned(note)
        try await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: isolatedLedger()).uploadNote(note, token: "t", retryAuthOnFailure: false)
        let post = try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "POST" })
        XCTAssertTrue(colourOnly(colourProps(bodyJSON(post))).isEmpty, "云端本来没有颜色 → 新对象也不写颜色")
        XCTAssertTrue(colourProps(bodyJSON(post)).contains { ($0["value"] as? String) == "IPM.StickyNote" })
    }

    func testReplaceFallbackWhenTheOldObjectCannotBeReadCarriesOnlyTheCachedNoteJSONOrNothing() async throws {
        for cached in ["{\"color\":3,\"document\":{}}", nil] as [String?] {
            MockURLProtocol.reset()
            MockURLProtocol.handler = { req in
                switch req.httpMethod {
                case "PATCH": return .http(status: 403, json: [:])
                case "GET": return .http(status: 500, json: [:])
                case "POST": return .http(status: 201, json: ["id": "R-NEW", "changeKey": "CK2", "body": ["content": "<div>x</div>"]])
                default: return .http(status: 204, json: nil)
                }
            }
            let note = StickyNote(color: .pink, content: "x", remoteId: "R-OLD", changeKey: "CK1")
            note.webNoteJSON = cached
            insertOwned(note)
            try await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: isolatedLedger()).uploadNote(note, token: "t", retryAuthOnFailure: false)
            let colours = colourOnly(colourProps(bodyJSON(try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "POST" }))))
            XCTAssertNil(propValue(colours, id: colorPropId), "读取失败时绝不写 0x8B00")
            XCTAssertEqual(propValue(colours, id: webNotePropId), cached, "只搬运缓存的云端 _Note 原文；没有缓存就不写")
            XCTAssertEqual(note.webNoteJSON, cached)
        }
    }

    func testReplaceFallbackStillWritesTheLocalColourWhenTheUserChangedIt() async throws {
        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "PATCH": return .http(status: 404, json: [:])
            case "POST": return .http(status: 201, json: ["id": "R-NEW", "changeKey": "CK2", "body": ["content": "<div>x</div>"]])
            default: return .http(status: 204, json: nil)
            }
        }
        let note = StickyNote(color: .yellow, content: "x", remoteId: "R-OLD", changeKey: "CK1")
        insertOwned(note)
        let ledger = isolatedLedger()
        note.setColor(.charcoal, ledger: ledger)
        try await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger).uploadNote(note, token: "t", retryAuthOnFailure: false)
        XCTAssertEqual(MockURLProtocol.requests.map(\.method), ["PATCH", "POST", "DELETE"], "用户改过色：不需要读旧对象")
        let props = colourProps(bodyJSON(try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "POST" })))
        try assertWebNoteColor(props, expected: 6)
        XCTAssertFalse(ledger.isDirty(note.id))
    }

    func testBrandNewLocalNoteStillWritesItsColourOnCreate() async throws {
        MockURLProtocol.handler = { _ in .http(status: 201, json: ["id": "R-1", "changeKey": "CK", "body": ["content": "<div>n</div>"]]) }
        let note = StickyNote(color: .purple, content: "n")
        insertOwned(note)
        try await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: isolatedLedger()).uploadNote(note, token: "t")
        let props = colourProps(bodyJSON(try XCTUnwrap(MockURLProtocol.requests.first)))
        try assertWebNoteColor(props, expected: 3)
    }

    func testConflictCopyOfAnUntouchedColourCarriesOnlyTheCachedNoteJSON() async throws {
        let ledger = isolatedLedger()
        let local = StickyNote(color: .blue, content: "local edit", remoteId: "R-C", changeKey: "OLD", syncStatus: .pendingUpload)
        local.modifiedAt = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        local.webNoteJSON = "{\"color\":2,\"document\":{}}"
        insertOwned(local)
        try ctx.save()
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [self.message(id: "R-C", changeKey: "NEW", html: "<div>cloud edit</div>", color: 5, modified: "2030-01-01T00:00:00Z")]])
            }
            return .http(status: 201, json: ["id": "R-COPY", "changeKey": "K"])
        }
        await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger).syncAll(modelContext: ctx)
        let copy = try XCTUnwrap(try ctx.fetch(FetchDescriptor<StickyNote>()).first { $0.plainTextContent == "local edit" })
        XCTAssertEqual(copy.remoteId, "R-COPY")
        let post = try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "POST" })
        let colours = colourOnly(colourProps(bodyJSON(post)))
        XCTAssertNil(propValue(colours, id: colorPropId), "冲突副本不写 0x8B00")
        XCTAssertEqual(propValue(colours, id: webNotePropId), "{\"color\":2,\"document\":{}}", "只搬运缓存的云端 _Note，不用本地推断色")
        XCTAssertFalse(ledger.isCarry(copy.id), "创建成功后标记清除")
        XCTAssertEqual(local.noteColor, .gray, "主便笺取云端颜色")
    }

    func testConflictCopyOfALocallyChosenColourWritesItAndThePrimaryTakesTheCloudColour() async throws {
        let ledger = isolatedLedger()
        let local = StickyNote(color: .pink, content: "local edit", remoteId: "R-C", changeKey: "OLD", syncStatus: .pendingUpload)
        local.modifiedAt = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        insertOwned(local)
        try ctx.save()
        ledger.markDirty(local.id)
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [self.message(id: "R-C", changeKey: "NEW", html: "<div>cloud edit</div>", color: 5, modified: "2030-01-01T00:00:00Z")]])
            }
            return .http(status: 201, json: ["id": "R-COPY", "changeKey": "K"])
        }
        await SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger).syncAll(modelContext: ctx)
        let post = try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "POST" })
        try assertWebNoteColor(colourProps(bodyJSON(post)), expected: 2)
        XCTAssertFalse(ledger.isDirty(local.id), "主便笺已取云端颜色，不再脏")
        XCTAssertEqual(local.noteColor, .gray)
    }

    func testColourLedgerIsExclusivePersistentBoundedAndKeepsTheSchemaUntouched() {
        let name = "color-ledger-" + UUID().uuidString; ledgerSuites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        let ledger = ColorEditLedger(defaults: defaults)
        let a = UUID(), b = UUID()
        XCTAssertFalse(ledger.isDirty(a)); XCTAssertFalse(ledger.isCarry(a))
        ledger.markDirty(a); ledger.markCarry(b)
        XCTAssertTrue(ColorEditLedger(defaults: defaults).isDirty(a), "重启后仍在")
        ledger.markCarry(a)
        XCTAssertFalse(ledger.isDirty(a)); XCTAssertTrue(ledger.isCarry(a), "dirty 与 carry 互斥")
        ledger.clearCarry(a); ledger.clearDirty(b)
        XCTAssertFalse(ledger.isCarry(a)); XCTAssertTrue(ledger.isCarry(b))
        let first = UUID(); ledger.markDirty(first)
        for _ in 0..<ColorEditLedger.capacity { ledger.markDirty(UUID()) }
        XCTAssertFalse(ledger.isDirty(first), "容量封顶，最旧的被丢弃（丢失 = 保守：不写颜色）")
        XCTAssertFalse(Schema([StickyNote.self]).entities.first!.properties.map(\.name).contains { $0.lowercased().contains("dirty") },
                       "标记不进 SwiftData 存储，库结构与 c34d2e7/f23e122 完全一致")
    }

    func testCloudDeletedNoteIsDeletedLocallyOnPull() async throws {
        let note = StickyNote(color: .yellow, content: "Note to delete", remoteId: "R-CLOUD-DEL", changeKey: "CK-1", syncStatus: .synced)
        insertOwned(note)
        try ctx.save()

        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" && req.url?.path.contains("messages") == true {
                // Cloud returns empty list, meaning note was deleted in the cloud
                return .http(status: 200, json: ["value": []])
            }
            return .http(status: 200, json: [:])
        }

        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        await engine.syncAll(modelContext: ctx)

        let remaining = try ctx.fetch(FetchDescriptor<StickyNote>())
        XCTAssertTrue(remaining.filter { $0.remoteId == "R-CLOUD-DEL" }.isEmpty, "云端已删除的便笺在本地必须同步删除")
    }

    func testUntouchedBlankNewNoteIsNotPushedUntilEdited() async throws {
        let blank = StickyNote(color: .yellow, content: "")
        insertOwned(blank)
        try ctx.save()

        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        XCTAssertTrue(engine.isUntouchedBlankNewNote(blank), "新建空便笺应判定为 untouched")

        var postCount = 0
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" { return .http(status: 200, json: ["value": []]) }
            if req.httpMethod == "POST" {
                postCount += 1
                return .http(status: 201, json: ["id": "R-NEW", "changeKey": "CK-NEW"])
            }
            return .http(status: 200, json: [:])
        }

        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(postCount, 0, "未触碰的空白便笺不得自动上传")
        XCTAssertNil(blank.remoteId)
        XCTAssertEqual(engine.state, .idle, "未触碰空白便笺不应把同步状态标为错误")
        XCTAssertEqual(engine.incompleteTaskCount, 0)

        // Now edit text
        blank.plainTextContent = "Now has text"
        XCTAssertFalse(engine.isUntouchedBlankNewNote(blank), "输入正文后不再视为 untouched")

        await engine.syncAll(modelContext: ctx)
        XCTAssertEqual(postCount, 1, "输入正文后正常触发上传")
        XCTAssertEqual(blank.remoteId, "R-NEW")
    }

    func testSameChangeKeyPullHealsSyncedLocalColor() async throws {
        let local = StickyNote(color: .gray, content: "same", remoteId: "R-HEAL", changeKey: "CK-SAME", syncStatus: .synced)
        insertOwned(local)
        try ctx.save()

        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [self.message(id: "R-HEAL", changeKey: "CK-SAME", html: "<div>same</div>", color: 3)]])
            }
            return .http(status: 200, json: [:])
        }

        let ledger = isolatedLedger()
        let engine = SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger)
        await engine.syncAll(modelContext: ctx)

        XCTAssertEqual(local.noteColor, .purple, "已同步且本地未改色的便笺在同 changeKey 拉取时应按云端校正颜色")
    }

    func testApplyGraphTimestampsDoesNotOverwriteOriginalCreatedAtOnUpdate() async throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let note = StickyNote(color: .yellow, content: "Existing Note", remoteId: "R-EXISTING", changeKey: "CK-1", syncStatus: .pendingUpload)
        note.createdAt = originalDate
        insertOwned(note)
        try ctx.save()

        MockURLProtocol.handler = { req in
            if req.httpMethod == "PATCH" {
                // Server 403 fallback to recreate
                return .http(status: 403, json: ["error": "forbidden"])
            }
            if req.httpMethod == "POST" {
                return .http(status: 201, json: [
                    "id": "R-NEW-MSG",
                    "changeKey": "CK-NEW-MSG",
                    "createdDateTime": "2030-01-01T12:00:00Z",
                    "lastModifiedDateTime": "2030-01-01T12:05:00Z",
                    "body": ["contentType": "html", "content": "<div>Existing Note</div>"]
                ])
            }
            if req.httpMethod == "GET" { return .http(status: 200, json: ["value": []]) }
            return .http(status: 200, json: [:])
        }

        let engine = SyncEngine(authManager: SyncAuthStub.shared)
        await engine.syncAll(modelContext: ctx)

        XCTAssertEqual(note.createdAt, originalDate, "替换更新不得篡改原本地创建时间")
    }

    func testHealIncompleteSubstrateNotesUpgradesLegacyMacAuthoredNotesAndUploads() async throws {
        let legacyJSON = "{\"schemaVersion\":\"beta\",\"#type.color\":\"Int32\",\"color\":3,\"color@Is.Queryable\":\"True\"}"
        let note = StickyNote(color: .purple, content: "legacy mac note", remoteId: "R-LEGACY", changeKey: "CK1", syncStatus: .synced)
        note.webNoteJSON = legacyJSON
        insertOwned(note)
        try ctx.save()

        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                return .http(status: 200, json: ["value": [
                    [
                        "id": "R-LEGACY",
                        "changeKey": "CK1",
                        "subject": "legacy mac note",
                        "body": ["contentType": "html", "content": "<div>legacy mac note</div>"],
                        "createdDateTime": "2026-01-01T00:00:00Z",
                        "lastModifiedDateTime": "2026-01-01T00:00:00Z",
                        "singleValueExtendedProperties": [
                            ["id": NoteConverter.pidLidNoteColorPropertyId, "value": "4"],
                            ["id": NoteConverter.webNoteJSONPropertyId, "value": legacyJSON]
                        ]
                    ]
                ]])
            }
            if req.httpMethod == "PATCH" {
                return .http(status: 200, json: ["id": "R-LEGACY", "changeKey": "CK2", "body": ["content": "<div>legacy mac note</div>"]])
            }
            return .http(status: 400, json: [:])
        }

        let ledger = isolatedLedger()
        let engine = SyncEngine(authManager: SyncAuthStub.shared, colorLedger: ledger)
        await engine.syncAll(modelContext: ctx)

        XCTAssertEqual(note.syncStatus, .synced)
        XCTAssertTrue(NoteConverter.hasCompleteSubstrateDocument(note.webNoteJSON), "遗留残缺笔记在同步时被成功升级为完整 Substrate document")

        let patch = try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "PATCH" })
        let body = try XCTUnwrap(self.bodyJSON(patch))
        let props = try XCTUnwrap(body["singleValueExtendedProperties"] as? [[String: Any]])
        XCTAssertTrue(props.contains { ($0["id"] as? String) == NoteConverter.pidTagIconIndexPropertyId }, "上传时必须携带 PidTagIconIndex (0x1080)")
        XCTAssertTrue(props.contains { ($0["id"] as? String) == NoteConverter.pidLidNoteColorPropertyId }, "上传时必须携带 PidLidNoteColor (0x8B00)")
        let webProp = try XCTUnwrap(props.first { ($0["id"] as? String) == NoteConverter.webNoteJSONPropertyId })
        let webVal = try XCTUnwrap(webProp["value"] as? String)
        XCTAssertTrue(NoteConverter.hasCompleteSubstrateDocument(webVal), "上传的 _Note 必须是完整的 Substrate document")
    }
}

import XCTest
import SwiftData
import AppKit

/// 模块 1：核心模型与数据持久化（SwiftData）
@MainActor
final class StickyNoteModelTests: XCTestCase {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([StickyNote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    func testDefaultValues() {
        let note = StickyNote()
        XCTAssertEqual(note.noteColor, .yellow)
        XCTAssertEqual(note.colorRawValue, "yellow")
        XCTAssertEqual(note.plainTextContent, "")
        XCTAssertNil(note.attributedContentData)
        XCTAssertEqual(note.syncStatus, .pendingUpload)
        XCTAssertNil(note.remoteId)
        XCTAssertNil(note.changeKey)
        XCTAssertNil(note.lastSyncedAt)
        XCTAssertEqual(note.windowWidth, 300)
        XCTAssertEqual(note.windowHeight, 350)
        XCTAssertFalse(note.isOpen)
        XCTAssertTrue(note.audioRecordings.isEmpty)
        XCTAssertEqual(note.title, "New Note", "空便签标题应回退为 New Note")
        XCTAssertEqual(note.preview, "")
    }

    func testInitialWindowPositionInsideVisibleScreen() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        for _ in 0..<200 {
            let n = StickyNote()
            XCTAssertGreaterThanOrEqual(n.windowX, Double(screen.minX))
            XCTAssertGreaterThanOrEqual(n.windowY, Double(screen.minY))
            XCTAssertLessThanOrEqual(n.windowX + n.windowWidth, Double(screen.maxX))
            XCTAssertLessThanOrEqual(n.windowY + n.windowHeight, Double(screen.maxY))
        }
    }

    func testUUIDUniqueness() {
        let ids = (0..<5000).map { _ in StickyNote().id }
        XCTAssertEqual(Set(ids).count, 5000)
    }

    func testCRUDInMemory() throws {
        let container = try makeInMemoryContainer()
        let ctx = container.mainContext

        // Create
        let a = StickyNote(color: .blue, content: "Alpha\nsecond line")
        let b = StickyNote(color: .pink, content: "Beta")
        ctx.insert(a); ctx.insert(b)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<StickyNote>()), 2)

        // Read
        let aid = a.id
        let fetched = try ctx.fetch(FetchDescriptor<StickyNote>(predicate: #Predicate { $0.id == aid }))
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.title, "Alpha")
        XCTAssertEqual(fetched.first?.preview, "second line")
        XCTAssertEqual(fetched.first?.noteColor, .blue)

        // Update
        let before = a.modifiedAt
        a.syncStatus = .synced
        Thread.sleep(forTimeInterval: 0.01)
        a.setColor(.green)
        try ctx.save()
        XCTAssertEqual(a.noteColor, .green)
        XCTAssertGreaterThan(a.modifiedAt, before)
        XCTAssertEqual(a.syncStatus, .pendingUpload, "改色后应重新标记为待上传")

        // Delete
        ctx.delete(b)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<StickyNote>()), 1)
    }

    /// 本地落盘 + 窗口位置记忆（模型层）：写入磁盘 store，重新打开容器后数据仍在。
    func testOnDiskPersistenceOfContentColorAndWindowFrame() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sn-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("qa.store")
        let schema = Schema([StickyNote.self])

        let attr = NSMutableAttributedString(string: "Bold ", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        attr.append(NSAttributedString(string: "plain", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        var savedID = UUID()
        do {
            let c = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let n = StickyNote(color: .purple, content: "Bold plain")
            n.attributedContentData = try NSKeyedArchiver.archivedData(withRootObject: attr, requiringSecureCoding: true)
            n.windowX = 123; n.windowY = 456; n.windowWidth = 333; n.windowHeight = 444
            c.mainContext.insert(n)
            try c.mainContext.save()
            savedID = n.id
        }
        let c2 = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let sid = savedID
        let back = try XCTUnwrap(try c2.mainContext.fetch(FetchDescriptor<StickyNote>(predicate: #Predicate { $0.id == sid })).first)
        XCTAssertEqual(back.plainTextContent, "Bold plain")
        XCTAssertEqual(back.noteColor, .purple)
        XCTAssertEqual(back.windowX, 123); XCTAssertEqual(back.windowY, 456)
        XCTAssertEqual(back.windowWidth, 333); XCTAssertEqual(back.windowHeight, 444)
        let data = try XCTUnwrap(back.attributedContentData)
        let restored = try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSAttributedString.self, NSFont.self, NSColor.self, NSParagraphStyle.self, NSShadow.self, NSTextAttachment.self],
            from: data) as? NSAttributedString)
        XCTAssertEqual(restored.string, "Bold plain")
        let f = try XCTUnwrap(restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testAllSixPlusThemeColorsPersist() throws {
        let container = try makeInMemoryContainer()
        let ctx = container.mainContext
        for color in NoteColor.allCases {
            let n = StickyNote(color: color)
            ctx.insert(n)
        }
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(Set(all.map(\.noteColor)), Set(NoteColor.allCases))
    }

    func testInvalidRawValuesFallBack() {
        let n = StickyNote()
        n.colorRawValue = "not-a-color"
        n.syncStatusRaw = "garbage"
        XCTAssertEqual(n.noteColor, .yellow)
        XCTAssertEqual(n.syncStatus, .pendingUpload)
    }

    func testAudioRecordingMutations() {
        let n = StickyNote()
        n.syncStatus = .synced
        n.addAudioRecording(Data([1, 2, 3]))
        XCTAssertEqual(n.audioRecordings.count, 1)
        XCTAssertEqual(n.syncStatus, .pendingUpload)
        n.syncStatus = .synced
        n.removeAudioRecording(at: 5) // out of range: no-op
        XCTAssertEqual(n.audioRecordings.count, 1)
        XCTAssertEqual(n.syncStatus, .synced)
        n.removeAudioRecording(at: 0)
        XCTAssertTrue(n.audioRecordings.isEmpty)
        XCTAssertEqual(n.syncStatus, .pendingUpload)
    }

    func testHiddenTextRedactedInTitleAndPreview() throws {
        let text = "Secret pin 1234\nline two"
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.hiddenText, value: true, range: NSRange(location: 11, length: 4))
        let n = StickyNote(content: text)
        n.attributedContentData = try NSKeyedArchiver.archivedData(withRootObject: attr, requiringSecureCoding: true)
        XCTAssertEqual(n.title, "Secret pin •••")
        XCTAssertFalse(n.title.contains("1234"))
        XCTAssertEqual(n.preview, "line two")
    }

    /// 极长文本：标题截断 100、预览截断 200。
    func testVeryLongTextTitleAndPreviewTruncation() {
        let long = String(repeating: "长", count: 100_000) + "\n" + String(repeating: "x", count: 100_000)
        let n = StickyNote(content: long)
        XCTAssertEqual(n.title.count, 100)
        XCTAssertEqual(n.preview.count, 200)
    }

    func testVisibleNewestFirstSortsByModifiedAtAndHidesTombstones() {
        let older = StickyNote(content: "older")
        let newer = StickyNote(content: "newer")
        let tombstone = StickyNote(content: "gone")
        older.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        newer.modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        tombstone.modifiedAt = Date(timeIntervalSince1970: 1_900_000_000)
        tombstone.isDeletedLocally = true
        let ranked = StickyNote.visibleNewestFirst([older, newer, tombstone])
        XCTAssertEqual(ranked.map(\.plainTextContent), ["newer", "older"])
    }

    func testResolvedModifiedAtDoesNotLetStaleRemoteBuryLocal() {
        let local = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = Date(timeIntervalSince1970: 946_684_800)
        XCTAssertEqual(StickyNote.resolvedModifiedAt(local: local, remote: stale), local)
        XCTAssertEqual(StickyNote.resolvedModifiedAt(local: local, remote: nil), local)
        let newer = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertEqual(StickyNote.resolvedModifiedAt(local: local, remote: newer), newer)
    }

    func testSyncStatusRawValuesStable() {
        // Raw values are persisted in the store; changing them would break existing data.
        XCTAssertEqual(SyncStatus.synced.rawValue, "synced")
        XCTAssertEqual(SyncStatus.pendingUpload.rawValue, "pendingUpload")
        XCTAssertEqual(SyncStatus.error.rawValue, "error")
        XCTAssertEqual(SyncStatus.allCases.count, 3)
    }
}

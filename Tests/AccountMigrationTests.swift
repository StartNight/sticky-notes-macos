import XCTest
import SwiftData
import Foundation

/// A baseline-compatible schema, written only into a freshly created test directory.
private enum LegacyAccountSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [StickyNote.self] }
    @Model final class StickyNote {
        var id: UUID
        var plainTextContent: String
        var attributedContentData: Data?
        var colorRawValue: String
        var windowX: Double
        var windowY: Double
        var windowWidth: Double
        var windowHeight: Double
        var createdAt: Date
        var modifiedAt: Date
        var isOpen: Bool
        @Attribute(.externalStorage) var audioRecordings: [Data]
        var remoteId: String?
        var changeKey: String?
        var syncStatusRaw: String
        var lastSyncedAt: Date?
        var isDeletedLocally: Bool = false
        var webNoteJSON: String?
        init() {
            id = UUID(); plainTextContent = "legacy-private"; attributedContentData = Data([1, 2, 3])
            colorRawValue = "yellow"; windowX = 123; windowY = 234; windowWidth = 300; windowHeight = 350
            createdAt = Date(timeIntervalSince1970: 12345); modifiedAt = Date(timeIntervalSince1970: 23456)
            isOpen = false; audioRecordings = [Data([4, 5, 6])]
            remoteId = "legacy-id"; changeKey = "legacy-key"; syncStatusRaw = "pendingUpload"
            lastSyncedAt = nil; webNoteJSON = "legacy-json"
        }
    }
}

@MainActor
final class AccountMigrationTests: XCTestCase {
    func testLegacyDiskStoreMigratesWithoutAssigningOrLosingContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("migration.store")
        let oldSchema = Schema(LegacyAccountSchema.models)
        do {
            let old = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, url: url)])
            let context = ModelContext(old)
            context.insert(LegacyAccountSchema.StickyNote())
            try context.save()
        }
        let schema = Schema([StickyNote.self])
        let current = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let notes = try current.mainContext.fetch(FetchDescriptor<StickyNote>())
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(notes.count, 1)
        XCTAssertNil(note.ownerAccountID, "归属未知的旧便笺不得绑定到首个登录账号")
        XCTAssertEqual(note.plainTextContent, "legacy-private")
        XCTAssertEqual(note.remoteId, "legacy-id")
        XCTAssertEqual(note.changeKey, "legacy-key")
        XCTAssertEqual(note.webNoteJSON, "legacy-json")
        XCTAssertEqual(note.attributedContentData, Data([1, 2, 3]))
        XCTAssertEqual(note.audioRecordings, [Data([4, 5, 6])])
        XCTAssertEqual(note.windowX, 123)
        XCTAssertEqual(note.windowY, 234)
        XCTAssertEqual(note.modifiedAt, Date(timeIntervalSince1970: 23456))
    }
}

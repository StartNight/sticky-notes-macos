import XCTest
import SwiftData

@MainActor
final class SyncJournalPersistenceTests: XCTestCase {
    func testUncertainCreateAndRetiredIDsSurviveDiskReopenWithContentAndOwner() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("journal.store")
        let schema = Schema([StickyNote.self])
        do {
            let store = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = ModelContext(store)
            let note = StickyNote(content: "retained-private", remoteId: "last-known-old", ownerAccountID: "fake-A")
            note.pendingCreateOperationID = "fake-op"
            note.pendingCreateEndpoint = "/v1.0/me/mailFolders/notes/messages"
            note.pendingCreateStartedAt = Date(timeIntervalSince1970: 123456)
            note.pendingCleanupRemoteIDs = ["retired-1", "retired-2"]
            note.isDeletedLocally = true
            context.insert(note)
            try context.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let note = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<StickyNote>()).first)
        XCTAssertEqual(note.plainTextContent, "retained-private")
        XCTAssertEqual(note.ownerAccountID, "fake-A")
        XCTAssertEqual(note.remoteId, "last-known-old")
        XCTAssertEqual(note.pendingCreateOperationID, "fake-op")
        XCTAssertEqual(note.pendingCreateEndpoint, "/v1.0/me/mailFolders/notes/messages")
        XCTAssertEqual(note.pendingCreateStartedAt, Date(timeIntervalSince1970: 123456))
        XCTAssertEqual(note.pendingCleanupRemoteIDs, ["retired-1", "retired-2"])
        XCTAssertTrue(note.isDeletedLocally)
    }
}

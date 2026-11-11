import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    enum EngineState: Equatable {
        case idle
        case syncing
        case error(String)
        case offline

        var displayText: String {
            switch self {
            case .idle: return String(localized: "Synced")
            case .syncing: return String(localized: "Syncing...")
            case .error(let msg): return String(localized: "Error: \(msg)")
            case .offline: return String(localized: "Offline")
            }
        }

        var systemImage: String {
            switch self {
            case .idle: return "checkmark.icloud"
            case .syncing: return "arrow.triangle.2.circlepath.circle"
            case .error: return "exclamationmark.icloud"
            case .offline: return "bolt.horizontal.icloud"
            }
        }
    }

    // MARK: - State
    var state: EngineState = .idle
    var lastSyncDate: Date? {
        get {
            let timestamp = UserDefaults.standard.double(forKey: lastSyncKey)
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: lastSyncKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastSyncKey)
            }
        }
    }

    private let authManager: any SyncAuthProviding
    private let graphEndpoint = "https://graph.microsoft.com/v1.0"
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var periodicTimer: Timer?
    private let debounceNanoseconds: UInt64
    private var fullSyncRunning = false
    private var uploadingNoteIDs: Set<UUID> = []
    private var uploadWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    func uploadWaiterCount(for id: UUID) -> Int { uploadWaiters[id]?.count ?? 0 }

    private func acquireUpload(_ id: UUID) async {
        if uploadingNoteIDs.insert(id).inserted { return }
        await withCheckedContinuation { uploadWaiters[id, default: []].append($0) }
    }
    private func releaseUpload(_ id: UUID) {
        if var waiters = uploadWaiters[id], !waiters.isEmpty {
            let next = waiters.removeFirst()
            uploadWaiters[id] = waiters
            next.resume() // lock ownership transfers; never opens a second POST window
        } else { uploadingNoteIDs.remove(id); uploadWaiters.removeValue(forKey: id) }
    }

    private struct UploadSnapshot {
        let text: String
        let richText: Data?
        let color: NoteColor
        let modified: Date
        let audio: [Data]
        init(_ note: StickyNote) {
            text = note.plainTextContent; richText = note.attributedContentData
            color = note.noteColor; modified = note.modifiedAt; audio = note.audioRecordings
        }
        func matches(_ note: StickyNote) -> Bool {
            text == note.plainTextContent && richText == note.attributedContentData &&
            color == note.noteColor && modified == note.modifiedAt && audio == note.audioRecordings
        }
    }
    private func syncError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "SyncEngine", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func saveDurably(_ note: StickyNote) throws {
        guard let context = note.modelContext else { throw syncError(-33, "便笺未存入本地数据库，已阻止远端写入。") }
        try context.save()
    }
    private func requireUploadable(_ note: StickyNote, scope: Scope) throws {
        try validate(scope)
        guard !note.isDeleted, !note.isDeletedLocally else { throw syncError(-32, "便笺已删除，停止上传。") }
        try requireOwner(note, scope: scope)
        guard !note.hasCorruptSyncJournal else { throw syncError(-36, "同步清理记录无法解析，已保留数据并阻止自动写入。") }
        guard note.pendingCreateOperationID == nil else {
            throw syncError(-30, "创建结果待确认：内容已保留，已阻止自动重建；请先核对云端对象，勿盲目重试。")
        }
    }
    /// Both deletion UIs must call this BEFORE removing a model or sending a DELETE.
    func prepareForDeletion(_ note: StickyNote, modelContext: ModelContext) throws {
        debounceTasks[note.id]?.cancel()
        debounceTasks.removeValue(forKey: note.id)
        let previousDeleted = note.isDeletedLocally
        let previousStatus = note.syncStatus
        note.isDeletedLocally = true
        note.syncStatus = .pendingUpload
        do { try modelContext.save() }
        catch {
            note.isDeletedLocally = previousDeleted
            note.syncStatus = previousStatus
            throw error
        }
    }

    /// Remote IDs deleted locally whose DELETE has not yet succeeded (in-memory retry queue).
    private var pendingRemoteDeletes: [String: Set<String>] = [:]
    private var lastSyncKey: String { "ms_last_sync_timestamp.account." + (authManager.accountID ?? "unverified") }

    struct Scope {
        let accountID: String
        let generation: UUID
    }
    private func currentScope() throws -> Scope {
        guard authManager.isAuthenticated, let id = authManager.accountID, !id.isEmpty else {
            throw NSError(domain: "SyncEngine", code: -20, userInfo: [NSLocalizedDescriptionKey: "账号身份未确认，已暂停同步。"])
        }
        return Scope(accountID: id, generation: authManager.sessionGeneration)
    }
    private func validate(_ scope: Scope) throws {
        guard authManager.isAuthenticated, authManager.accountID == scope.accountID,
              authManager.sessionGeneration == scope.generation else { throw CancellationError() }
    }
    private func scopedData(for request: URLRequest, scope: Scope) async throws -> (Data, URLResponse) {
        try validate(scope)
        do {
            let result = try await URLSession.shared.data(for: request)
            try validate(scope)
            return result
        } catch {
            try validate(scope)
            throw error
        }
    }
    private func refreshedToken(scope: Scope) async throws -> String {
        try validate(scope)
        let token = try await authManager.refreshTokens()
        try validate(scope)
        return token
    }
    /// Unowned/legacy notes stay local; ownership is never guessed from the first account to sign in.
    private func requireOwner(_ note: StickyNote, scope: Scope) throws {
        try validate(scope)
        guard note.ownerAccountID == scope.accountID else {
            throw NSError(domain: "SyncEngine", code: -21, userInfo: [NSLocalizedDescriptionKey: "此便笺不属于当前账号，仅保留在本地。"])
        }
    }


    init(authManager: any SyncAuthProviding = AuthManager.shared, debounceNanoseconds: UInt64 = 1_500_000_000) {
        self.authManager = authManager
        self.debounceNanoseconds = debounceNanoseconds
        startPeriodicSync()
    }

    /// Explicit opt-in only for never-synced local notes. Legacy remote links remain quarantined.
    func adoptLocalOnlyNotes(modelContext: ModelContext) throws -> Int {
        let scope = try currentScope()
        let notes = try modelContext.fetch(FetchDescriptor<StickyNote>())
        var count = 0
        for note in notes where note.ownerAccountID == nil && note.remoteId == nil && !note.isDeletedLocally {
            note.ownerAccountID = scope.accountID
            note.changeKey = nil
            note.webNoteJSON = nil
            note.lastSyncedAt = nil
            note.syncStatus = .pendingUpload
            count += 1
        }
        try modelContext.save()
        return count
    }

    // MARK: - Periodic Sync

    func startPeriodicSync() {
        periodicTimer?.invalidate()
        // Check sync every 5 minutes
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.authManager.isAuthenticated else { return }
                NotificationCenter.default.post(name: .requestModelContextSync, object: nil)
            }
        }
    }

    // MARK: - Full Sync (Pull + Push)

    func syncAll(modelContext: ModelContext) async {
        guard authManager.isAuthenticated else {
            self.state = .offline
            return
        }

        guard !fullSyncRunning else { return }
        fullSyncRunning = true
        defer { fullSyncRunning = false }
        self.state = .syncing

        do {
            let generation = authManager.sessionGeneration
            _ = try await authManager.ensureAccountID()
            guard generation == authManager.sessionGeneration else { throw CancellationError() }
            let scope = try currentScope()
            let token = try await authManager.getValidAccessToken()
            try validate(scope)
            let localJournalNotes = try modelContext.fetch(FetchDescriptor<StickyNote>())
            guard !localJournalNotes.contains(where: { $0.ownerAccountID == scope.accountID && $0.hasCorruptSyncJournal }) else {
                throw syncError(-36, "同步清理记录无法解析，已保留数据并停止同步。")
            }
            // 1. Pull remote changes
            try await pullNotes(token: token, modelContext: modelContext, scope: scope)
            // 2. Push pending local changes
            try await pushPendingNotes(token: token, modelContext: modelContext, scope: scope)
            try await pushPendingDeletes(token: token, modelContext: modelContext, scope: scope)
            try validate(scope)
            try ensureNoPendingWork(modelContext: modelContext, scope: scope)

            self.state = .idle
            self.lastSyncDate = Date()
        } catch is CancellationError {
            return
        } catch {
            print("Sync failed: code=\((error as NSError).code)")
            self.state = .error(error.localizedDescription)
        }
    }

    // MARK: - Pull Remote Notes

    private func pullNotes(token: String, modelContext: ModelContext, scope: Scope, retryAuthOnFailure: Bool = true) async throws {
        let lidId = NoteConverter.pidLidNoteColorPropertyId
        let webId = NoteConverter.webNoteJSONPropertyId
        let expandClause = "singleValueExtendedProperties($filter=id eq '\(lidId)' or id eq '\(webId)')"
        let encodedExpand = expandClause.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? expandClause
        let urlString = "\(graphEndpoint)/me/mailFolders/notes/messages?$top=100&$orderby=lastModifiedDateTime%20desc&$select=id,changeKey,subject,body,createdDateTime,lastModifiedDateTime&$expand=\(encodedExpand)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await scopedData(for: request, scope: scope)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        if httpResponse.statusCode == 401 {
            guard retryAuthOnFailure else {
                throw NSError(domain: "SyncEngine", code: 401, userInfo: [NSLocalizedDescriptionKey: "Pull failed: unauthorized"])
            }
            let newToken = try await refreshedToken(scope: scope)
            return try await pullNotes(token: newToken, modelContext: modelContext, scope: scope, retryAuthOnFailure: false)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let err = "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Pull failed: \(err)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["value"] as? [[String: Any]] else {
            return
        }

        // Fetch all local notes
        let descriptor = FetchDescriptor<StickyNote>()
        let localNotes = try modelContext.fetch(descriptor)
        if localNotes.contains(where: { $0.ownerAccountID == scope.accountID && $0.hasCorruptSyncJournal }) {
            throw syncError(-36, "同步清理记录无法解析，已保留数据并停止同步。")
        }
        var retiredIDs: Set<String> = []
        var localByRemoteId: [String: StickyNote] = [:]
        for note in localNotes where note.ownerAccountID == scope.accountID {
            retiredIDs.formUnion(note.pendingCleanupRemoteIDs)
            if let rId = note.remoteId {
                localByRemoteId[rId] = note
            }
        }

        for msg in messages {
            guard let remoteId = msg["id"] as? String,
                  let changeKey = msg["changeKey"] as? String else {
                continue
            }

            let bodyObj = msg["body"] as? [String: Any]
            let htmlContent = (bodyObj?["content"] as? String) ?? ""
            let plainText = NoteConverter.extractPlainText(from: htmlContent)

            let remoteModifiedDate = Self.plausibleGraphDate(msg["lastModifiedDateTime"] as? String)
            let remoteCreatedDate = Self.plausibleGraphDate(msg["createdDateTime"] as? String)

            // Prefer modern `_Note.color` (what web Sticky Notes reads); fall back to 0x8B00.
            let extracted = NoteConverter.extractNoteColor(
                fromExtendedProperties: (msg["singleValueExtendedProperties"] as? [[String: Any]]) ?? []
            )
            let noteColor = extracted.color
            let webNoteJSON = extracted.webNoteJSON

            let existingLocal = localByRemoteId[remoteId]
            if (pendingRemoteDeletes[scope.accountID] ?? []).contains(remoteId) ||
                existingLocal?.isDeletedLocally == true || retiredIDs.contains(remoteId) {
                // Never resurrect tombstones/retired objects. Durable delete replay is centralized
                // in pushPendingDeletes so failures propagate to the overall sync result.
                continue
            }

            if let localNote = existingLocal {
                // An unresolved POST may have committed. Keep its original content/metadata frozen
                // for explicit reconciliation; don't turn it into an auto-uploadable conflict copy.
                if localNote.pendingCreateOperationID != nil { continue }
                // Note exists locally
                if localNote.changeKey == changeKey {
                    // Still cache `_Note` JSON so a later color-only upload can merge into it.
                    if let webNoteJSON {
                        localNote.webNoteJSON = webNoteJSON
                    }
                    continue
                }

                // Cloud has changes
                if localNote.syncStatus == .pendingUpload || localNote.syncStatus == .error {
                    // Conflict Resolution:
                    // If cloud is newer, preserve cloud as primary and save local as copy
                    if let remoteModifiedDate, remoteModifiedDate > localNote.modifiedAt {
                        let copyNote = StickyNote(
                            color: localNote.noteColor,
                            content: localNote.plainTextContent
                        )
                        copyNote.ownerAccountID = scope.accountID
                        copyNote.attributedContentData = localNote.attributedContentData
                        copyNote.audioRecordings = localNote.audioRecordings
                        copyNote.webNoteJSON = localNote.webNoteJSON
                        copyNote.createdAt = localNote.createdAt
                        copyNote.modifiedAt = localNote.modifiedAt
                        copyNote.syncStatus = .pendingUpload
                        modelContext.insert(copyNote)

                        // Update current note with cloud content
                        localNote.plainTextContent = plainText
                        let attrStr = NoteConverter.htmlToAttributedString(htmlContent)
                        localNote.attributedContentData = try? NSKeyedArchiver.archivedData(withRootObject: attrStr, requiringSecureCoding: true)
                        localNote.noteColor = noteColor
                        if let webNoteJSON { localNote.webNoteJSON = webNoteJSON }
                        localNote.changeKey = changeKey
                        localNote.modifiedAt = StickyNote.resolvedModifiedAt(local: localNote.modifiedAt, remote: remoteModifiedDate)
                        if let remoteCreatedDate { localNote.createdAt = remoteCreatedDate }
                        localNote.syncStatus = .synced
                        localNote.lastSyncedAt = Date()
                    } else {
                        // Local is newer, let push step upload local
                        continue
                    }
                } else {
                    // No local modifications, cleanly update
                    localNote.plainTextContent = plainText
                    let attrStr = NoteConverter.htmlToAttributedString(htmlContent)
                    localNote.attributedContentData = try? NSKeyedArchiver.archivedData(withRootObject: attrStr, requiringSecureCoding: true)
                    localNote.noteColor = noteColor
                    if let webNoteJSON { localNote.webNoteJSON = webNoteJSON }
                    localNote.changeKey = changeKey
                    localNote.modifiedAt = StickyNote.resolvedModifiedAt(local: localNote.modifiedAt, remote: remoteModifiedDate)
                    if let remoteCreatedDate { localNote.createdAt = remoteCreatedDate }
                    localNote.syncStatus = .synced
                    localNote.lastSyncedAt = Date()
                }
            } else {
                // New note from cloud
                let newNote = StickyNote(
                    color: noteColor,
                    content: plainText,
                    remoteId: remoteId,
                    changeKey: changeKey,
                    syncStatus: .synced,
                    lastSyncedAt: Date()
                )
                let attrStr = NoteConverter.htmlToAttributedString(htmlContent)
                newNote.attributedContentData = try? NSKeyedArchiver.archivedData(withRootObject: attrStr, requiringSecureCoding: true)
                newNote.createdAt = remoteCreatedDate ?? Date()
                newNote.modifiedAt = remoteModifiedDate ?? remoteCreatedDate ?? Date()
                newNote.ownerAccountID = scope.accountID
                newNote.webNoteJSON = webNoteJSON
                modelContext.insert(newNote)
            }
        }

        try modelContext.save()
    }

    // MARK: - Push Pending Local Notes

    private func pushPendingNotes(token: String, modelContext: ModelContext, scope: Scope) async throws {
        try await pushPendingDeletes(token: token, modelContext: modelContext, scope: scope)

        let pendingStatus = SyncStatus.pendingUpload.rawValue
        let errorStatus = SyncStatus.error.rawValue
        let descriptor = FetchDescriptor<StickyNote>(
            predicate: #Predicate<StickyNote> { $0.syncStatusRaw == pendingStatus || $0.syncStatusRaw == errorStatus }
        )
        let pendingNotes = (try? modelContext.fetch(descriptor)) ?? []

        var uploadFailures = 0
        for note in pendingNotes where note.ownerAccountID == scope.accountID {
            if note.isDeletedLocally { continue }
            do {
                try await uploadNote(note, token: token, scope: scope)
            } catch {
                try validate(scope)
                print("Push failed: code=\((error as NSError).code)")
                if !(note.syncStatus == .synced && !note.pendingCleanupRemoteIDs.isEmpty) { note.syncStatus = .error }
                uploadFailures += 1
            }
        }

        try modelContext.save()

        if uploadFailures > 0 {
            throw NSError(
                domain: "SyncEngine",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to upload \(uploadFailures) note(s)"]
            )
        }
    }

    // MARK: - Upload Single Note (Create or Update)

    func uploadNote(_ note: StickyNote, token: String, retryAuthOnFailure: Bool = true, scope suppliedScope: Scope? = nil) async throws {
        let scope = try suppliedScope ?? currentScope()
        guard !note.isDeleted, !note.isDeletedLocally else { throw syncError(-32, "便笺已删除，停止上传。") }
        let id = note.id
        try requireOwner(note, scope: scope)
        await acquireUpload(id)
        defer { releaseUpload(id) }
        try Task.checkCancellation()
        try requireUploadable(note, scope: scope)
        // A concurrent sync/debounce may have already uploaded the exact current revision.
        if note.syncStatus == .synced { return }
        do {
            try await uploadLocked(note, token: token, retryAuthOnFailure: retryAuthOnFailure, scope: scope)
        } catch {
            if !note.isDeleted && !note.isDeletedLocally &&
                !(note.syncStatus == .synced && !note.pendingCleanupRemoteIDs.isEmpty) {
                note.syncStatus = .error
                try saveDurably(note)
            }
            throw error
        }
    }

    private func uploadLocked(_ note: StickyNote, token: String, retryAuthOnFailure: Bool, scope: Scope) async throws {
        try Task.checkCancellation()
        try requireUploadable(note, scope: scope)
        let snapshot = UploadSnapshot(note)
        let html: String
        if let data = note.attributedContentData,
           let attrStr = try? NSKeyedUnarchiver.unarchivedObject(
               ofClasses: [NSAttributedString.self, NSFont.self, NSColor.self,
                           NSParagraphStyle.self, NSShadow.self, NSTextAttachment.self],
               from: data
           ) as? NSAttributedString {
            html = NoteConverter.attributedStringToHtml(attrStr)
        } else {
            html = NoteConverter.plainTextToHtml(note.plainTextContent)
        }

        let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = trimmedTitle.isEmpty ? "New Note" : trimmedTitle

        let payload: [String: Any] = [
            "subject": subject,
            "body": [
                "contentType": "html",
                "content": html
            ],
            "singleValueExtendedProperties": NoteConverter.graphColorExtendedProperties(
                for: note.noteColor,
                existingWebNoteJSON: note.webNoteJSON
            )
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        if let remoteId = note.remoteId {
            guard let url = graphItemURL(collection: "me/notes", id: remoteId) else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid note URL"])
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=representation", forHTTPHeaderField: "Prefer")
            request.httpBody = jsonData

            let (data, response) = try await scopedData(for: request, scope: scope)
            guard let httpResponse = response as? HTTPURLResponse else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
            }

            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) && retryAuthOnFailure {
                let newToken = try await refreshedToken(scope: scope)
                return try await uploadLocked(note, token: newToken, retryAuthOnFailure: false, scope: scope)
            }

            // /me/notes requires ShortNotes.ReadWrite. Existing Mail.ReadWrite
            // sessions get 403/404; Graph also silently no-ops body writes on
            // PATCH /me/messages for non-draft notes. Recreate instead.
            if [400, 403, 404].contains(httpResponse.statusCode) {
                try await replaceRemoteNote(note, token: token, scope: scope, payloadData: jsonData, uploadedHTML: html, snapshot: snapshot)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                note.syncStatus = .error
                let responseBody = "Graph request failed"
                print("Failed to update note (HTTP \(httpResponse.statusCode)): \(responseBody)")
                throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to update note (HTTP \(httpResponse.statusCode)): \(responseBody)"
                ])
            }

            try finishUpload(note, data: data, uploadedHTML: html, isCreate: false, snapshot: snapshot)
        } else {
            guard let notesURL = URL(string: "\(graphEndpoint)/me/notes") else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid notes URL"])
            }
            let (data, httpResponse) = try await sendCreate(note, url: notesURL, token: token, body: jsonData, scope: scope)

            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) && retryAuthOnFailure {
                let newToken = try await refreshedToken(scope: scope)
                return try await uploadLocked(note, token: newToken, retryAuthOnFailure: false, scope: scope)
            }

            if [400, 403, 404].contains(httpResponse.statusCode) {
                try await createNoteInMailFolder(note, token: token, scope: scope, payloadData: jsonData, uploadedHTML: html, snapshot: snapshot)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                note.syncStatus = .error
                let responseBody = "Graph request failed"
                print("Failed to create note (HTTP \(httpResponse.statusCode)): \(responseBody)")
                throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create note (HTTP \(httpResponse.statusCode)): \(responseBody)"
                ])
            }

            try finishUpload(note, data: data, uploadedHTML: html, isCreate: true, snapshot: snapshot)
        }
    }

    /// Mail.ReadWrite fallback: create a replacement note then delete the old one.
    /// PATCH /me/messages cannot persist body/subject on non-draft Outlook notes.
    private func replaceRemoteNote(_ note: StickyNote, token: String, scope: Scope, payloadData: Data, uploadedHTML: String, snapshot: UploadSnapshot) async throws {
        try requireUploadable(note, scope: scope)
        let oldId = note.remoteId
        try await createNoteInMailFolder(note, token: token, scope: scope, payloadData: payloadData, uploadedHTML: uploadedHTML, snapshot: snapshot)
        if let oldId {
            // finishUpload durably journaled oldId before it replaced remoteId.
            try await performRemoteDelete(remoteId: oldId, token: token, scope: scope)
            note.pendingCleanupRemoteIDs.removeAll { $0 == oldId }
            try saveDurably(note)
        }
    }

    private func createNoteInMailFolder(_ note: StickyNote, token: String, scope: Scope, payloadData: Data, uploadedHTML: String, snapshot: UploadSnapshot) async throws {
        try requireUploadable(note, scope: scope)
        guard let url = URL(string: "\(graphEndpoint)/me/mailFolders/notes/messages") else {
            note.syncStatus = .error
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid notes folder URL"])
        }
        let mailPayload = Self.mailFolderCreatePayload(from: payloadData)
        let (data, httpResponse) = try await sendCreate(note, url: url, token: token, body: mailPayload, scope: scope)
        guard (200...299).contains(httpResponse.statusCode) else {
            note.syncStatus = .error
            let responseBody = "Graph request failed"
            throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create note (HTTP \(httpResponse.statusCode)): \(responseBody)"
            ])
        }
        try finishUpload(note, data: data, uploadedHTML: uploadedHTML, isCreate: true, snapshot: snapshot)
    }

    private func sendCreate(_ note: StickyNote, url: URL, token: String, body: Data, scope: Scope) async throws -> (Data, HTTPURLResponse) {
        try requireUploadable(note, scope: scope)
        try Task.checkCancellation()
        let operationID = UUID().uuidString
        note.pendingCreateOperationID = operationID
        note.pendingCreateEndpoint = url.path
        note.pendingCreateStartedAt = Date()
        // Crash/switch/timeout after this commit is uncertain, even if no response arrives.
        try saveDurably(note)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        // Correlation ONLY. Graph does not promise idempotency for this header.
        request.setValue(operationID, forHTTPHeaderField: "client-request-id")
        request.httpBody = body
        let (data, response) = try await scopedData(for: request, scope: scope)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw syncError(-30, "创建结果待确认：没有有效响应，已阻止自动重建。")
        }
        // Only an explicit definitive rejection releases the intent for a new attempt/fallback.
        if [400, 401, 403, 404, 405, 413, 415, 422, 429].contains(httpResponse.statusCode) {
            note.pendingCreateOperationID = nil
            note.pendingCreateEndpoint = nil
            note.pendingCreateStartedAt = nil
            try saveDurably(note)
        }
        return (data, httpResponse)
    }

    /// Never mark synced unless Graph returned a usable object. An empty 204/200
    /// or a 200 that echoes the old body is the false-success we must reject.
    private func finishUpload(_ note: StickyNote, data: Data, uploadedHTML: String, isCreate: Bool, snapshot: UploadSnapshot) throws {
        guard !note.isDeleted else { throw syncError(-32, "便笺已从本地删除，停止写回。") }
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            note.syncStatus = .error
            throw NSError(domain: "SyncEngine", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Upload response was empty; refusing to mark synced"
            ])
        }

        if isCreate {
            guard let newId = json["id"] as? String, !newId.isEmpty,
                  let newChangeKey = json["changeKey"] as? String, !newChangeKey.isEmpty else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "Create response missing id/changeKey; refusing to mark synced"
                ])
            }
            if let oldID = note.remoteId, oldID != newId, !note.pendingCleanupRemoteIDs.contains(oldID) {
                note.pendingCleanupRemoteIDs.append(oldID)
            }
            note.remoteId = newId
            note.changeKey = newChangeKey
            note.pendingCreateOperationID = nil
            note.pendingCreateEndpoint = nil
            note.pendingCreateStartedAt = nil
        } else {
            guard let newChangeKey = json["changeKey"] as? String, !newChangeKey.isEmpty else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "Update response missing changeKey; refusing to mark synced"
                ])
            }
            guard let content = (json["body"] as? [String: Any])?["content"] as? String else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "Update response missing body; refusing to mark synced"
                ])
            }
            let expected = NoteConverter.extractPlainText(from: uploadedHTML)
            let actual = NoteConverter.extractPlainText(from: content)
            if expected != actual {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "Server did not persist note body"
                ])
            }
            note.changeKey = newChangeKey
            if let newId = json["id"] as? String, !newId.isEmpty {
                note.remoteId = newId
            }
        }

        let unchanged = snapshot.matches(note) && !note.isDeletedLocally
        if unchanged { applyGraphTimestamps(json, to: note) }
        // Cache what was actually sent, never stamp a newer local color as already uploaded.
        note.webNoteJSON = NoteConverter.webNoteJSON(setting: snapshot.color, existing: note.webNoteJSON)
        note.syncStatus = unchanged ? .synced : .pendingUpload
        note.lastSyncedAt = Date()
        try saveDurably(note)
    }

    /// Mail-folder notes sort more reliably as IPM.StickyNote with current received/sent times.
    fileprivate static func mailFolderCreatePayload(from data: Data) -> Data {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }
        var props = obj["singleValueExtendedProperties"] as? [[String: Any]] ?? []
        let hasMessageClass = props.contains { id in
            let raw = (id["id"] as? String) ?? ""
            return raw.contains("0x001A") || raw.lowercased().contains("0x001a")
        }
        if !hasMessageClass {
            props.append(["id": "String 0x001A", "value": "IPM.StickyNote"])
        }
        obj["singleValueExtendedProperties"] = props
        let now = isoFormatterStandard.string(from: Date())
        if obj["receivedDateTime"] == nil { obj["receivedDateTime"] = now }
        if obj["sentDateTime"] == nil { obj["sentDateTime"] = now }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }

    private func applyGraphTimestamps(_ json: [String: Any], to note: StickyNote) {
        let remoteModified = Self.plausibleGraphDate(json["lastModifiedDateTime"] as? String)
        note.modifiedAt = StickyNote.resolvedModifiedAt(local: note.modifiedAt, remote: remoteModified)
        if let created = Self.plausibleGraphDate(json["createdDateTime"] as? String) {
            note.createdAt = created
        }
    }

    // MARK: - Debounced Push

    func scheduleDebouncedPush(for noteID: UUID, in modelContext: ModelContext) {
        // Capture login generation when scheduled, not after the debounce delay.
        guard let scope = try? currentScope() else { return }
        debounceTasks[noteID]?.cancel()

        debounceTasks[noteID] = Task {
            try? await Task.sleep(nanoseconds: debounceNanoseconds) // 1.5 seconds debounce
            guard !Task.isCancelled else { return }

            guard authManager.isAuthenticated else { return }

            let descriptor = FetchDescriptor<StickyNote>(
                predicate: #Predicate<StickyNote> { $0.id == noteID }
            )
            guard let note = try? modelContext.fetch(descriptor).first,
                  note.ownerAccountID == scope.accountID, !note.isDeletedLocally else { return }

            do {
                try validate(scope)
                self.state = .syncing
                let token = try await authManager.getValidAccessToken()
                try validate(scope)
                try await uploadNote(note, token: token, scope: scope)
                try await pushPendingDeletes(token: token, modelContext: modelContext, scope: scope)
                try modelContext.save()
                try ensureNoPendingWork(modelContext: modelContext, scope: scope)
                self.state = .idle
                self.lastSyncDate = Date()
            } catch is CancellationError {
                return
            } catch {
                print("Debounced push failed: code=\((error as NSError).code)")
                if !note.isDeleted && !note.isDeletedLocally &&
                    !(note.syncStatus == .synced && !note.pendingCleanupRemoteIDs.isEmpty) { note.syncStatus = .error }
                try? modelContext.save()
                self.state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Delete Note Remotely

    func deleteRemoteNote(remoteId: String, ownerAccountID: String?) {
        guard let scope = try? currentScope(), ownerAccountID == scope.accountID else { return }
        pendingRemoteDeletes[scope.accountID, default: []].insert(remoteId)
        Task {
            guard authManager.isAuthenticated else {
                self.state = .error("Delete pending until signed in")
                return
            }
            do {
                try validate(scope)
                let token = try await authManager.getValidAccessToken()
                try validate(scope)
                try await performRemoteDelete(remoteId: remoteId, token: token, scope: scope)
            } catch is CancellationError {
                return
            } catch {
                print("Delete failed: code=\((error as NSError).code)")
                self.state = .error(error.localizedDescription)
            }
        }
    }

    private func ensureNoPendingWork(modelContext: ModelContext, scope: Scope) throws {
        try validate(scope)
        let notes = try modelContext.fetch(FetchDescriptor<StickyNote>())
        if notes.contains(where: { $0.ownerAccountID == scope.accountID &&
            ($0.isDeletedLocally || $0.syncStatus != .synced || $0.pendingCreateOperationID != nil || $0.hasCorruptSyncJournal || !$0.pendingCleanupRemoteIDs.isEmpty) }) {
            throw syncError(-34, "仍有本地改动、删除或待确认创建未完成，未标记已同步。")
        }
    }

    private func pushPendingDeletes(token: String, modelContext: ModelContext, scope: Scope) async throws {
        try validate(scope)
        let localNotes = try modelContext.fetch(FetchDescriptor<StickyNote>()).filter { $0.ownerAccountID == scope.accountID }
        guard !localNotes.contains(where: { $0.hasCorruptSyncJournal }) else {
            throw syncError(-36, "同步清理记录无法解析，已保留数据并阻止删除。")
        }
        var ids = pendingRemoteDeletes[scope.accountID] ?? []
        var unresolved = 0
        for note in localNotes {
            // A replacement whose POST outcome is unknown must not lose its last known old object.
            if note.pendingCreateOperationID != nil {
                if note.isDeletedLocally { unresolved += 1 }
                continue
            }
            ids.formUnion(note.pendingCleanupRemoteIDs)
            if note.isDeletedLocally, let remoteId = note.remoteId { ids.insert(remoteId) }
        }
        var failures = 0
        for remoteId in ids {
            do {
                try await performRemoteDelete(remoteId: remoteId, token: token, scope: scope)
                for note in localNotes where !note.isDeleted {
                    if note.remoteId == remoteId && note.isDeletedLocally { note.remoteId = nil }
                    note.pendingCleanupRemoteIDs.removeAll { $0 == remoteId }
                }
                try modelContext.save() // every cleanup completion is durable before proceeding
            } catch {
                try validate(scope)
                failures += 1
                for note in localNotes where !note.isDeleted &&
                    (note.pendingCleanupRemoteIDs.contains(remoteId) || (note.isDeletedLocally && note.remoteId == remoteId)) {
                    if note.isDeletedLocally { note.syncStatus = .error }
                }
            }
        }
        for note in localNotes where !note.isDeleted && note.isDeletedLocally &&
            note.remoteId == nil && note.pendingCreateOperationID == nil && note.pendingCleanupRemoteIDs.isEmpty {
            modelContext.delete(note)
        }
        try modelContext.save()
        if failures + unresolved > 0 {
            throw syncError(-35, "删除/旧对象清理尚未完成或创建结果待确认，已保留重试记录。")
        }
    }

    private func performRemoteDelete(remoteId: String, token: String, scope: Scope, retryAuthOnFailure: Bool = true) async throws {
        guard let url = graphItemURL(collection: "me/messages", id: remoteId) else {
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid delete URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await scopedData(for: request, scope: scope)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) && retryAuthOnFailure {
            let newToken = try await refreshedToken(scope: scope)
            return try await performRemoteDelete(remoteId: remoteId, token: newToken, scope: scope, retryAuthOnFailure: false)
        }

        if httpResponse.statusCode == 404 {
            pendingRemoteDeletes[scope.accountID]?.remove(remoteId)
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = "Graph request failed"
            throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to delete note (HTTP \(httpResponse.statusCode)): \(responseBody)"
            ])
        }

        pendingRemoteDeletes[scope.accountID]?.remove(remoteId)
    }

    // MARK: - Graph URL Helpers

    private func graphItemURL(collection: String, id: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return URL(string: "\(graphEndpoint)/\(collection)/\(encoded)")
    }

    // MARK: - Date Formatting Helper


    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseGraphDate(_ string: String) -> Date? {
        if let date = isoFormatterFractional.date(from: string) ?? isoFormatterStandard.date(from: string) {
            return date
        }
        // Graph sometimes emits 7-digit fractional seconds that ISO8601DateFormatter rejects.
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let prefix = string[..<dot]
        let afterDot = string[string.index(after: dot)...]
        let digits = afterDot.prefix(while: { $0.isNumber })
        guard digits.count > 3 else { return nil }
        let suffix = afterDot.dropFirst(digits.count)
        let trimmed = "\(prefix).\(digits.prefix(3))\(suffix)"
        return isoFormatterFractional.date(from: trimmed)
            ?? isoFormatterStandard.date(from: "\(prefix)\(suffix)")
    }

    static func plausibleGraphDate(_ string: String?) -> Date? {
        guard let string, let date = parseGraphDate(string) else { return nil }
        let year2000 = Date(timeIntervalSince1970: 946_684_800)
        let year2100 = Date(timeIntervalSince1970: 4_102_444_800)
        guard date >= year2000, date <= year2100 else { return nil }
        return date
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let requestModelContextSync = Notification.Name("requestModelContextSync")
}

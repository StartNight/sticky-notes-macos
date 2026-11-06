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
            let timestamp = UserDefaults.standard.double(forKey: "ms_last_sync_timestamp")
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "ms_last_sync_timestamp")
            } else {
                UserDefaults.standard.removeObject(forKey: "ms_last_sync_timestamp")
            }
        }
    }

    private let authManager = AuthManager.shared
    private let graphEndpoint = "https://graph.microsoft.com/v1.0"
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var periodicTimer: Timer?
    /// Remote IDs deleted locally whose DELETE has not yet succeeded (in-memory retry queue).
    private var pendingRemoteDeletes: Set<String> = []

    init() {
        startPeriodicSync()
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

        self.state = .syncing

        do {
            let token = try await authManager.getValidAccessToken()
            // 1. Pull remote changes
            try await pullNotes(token: token, modelContext: modelContext)
            // 2. Push pending local changes
            try await pushPendingNotes(token: token, modelContext: modelContext)

            self.state = .idle
            self.lastSyncDate = Date()
        } catch {
            print("Sync failed: \(error)")
            self.state = .error(error.localizedDescription)
        }
    }

    // MARK: - Pull Remote Notes

    private func pullNotes(token: String, modelContext: ModelContext, retryAuthOnFailure: Bool = true) async throws {
        let lidId = NoteConverter.pidLidNoteColorPropertyId
        let webId = NoteConverter.webNoteJSONPropertyId
        let expandClause = "singleValueExtendedProperties($filter=id eq '\(lidId)' or id eq '\(webId)')"
        let encodedExpand = expandClause.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? expandClause
        let urlString = "\(graphEndpoint)/me/mailFolders/notes/messages?$top=100&$orderby=lastModifiedDateTime%20desc&$select=id,changeKey,subject,body,createdDateTime,lastModifiedDateTime&$expand=\(encodedExpand)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        if httpResponse.statusCode == 401 {
            guard retryAuthOnFailure else {
                throw NSError(domain: "SyncEngine", code: 401, userInfo: [NSLocalizedDescriptionKey: "Pull failed: unauthorized"])
            }
            let newToken = try await authManager.refreshTokens()
            return try await pullNotes(token: newToken, modelContext: modelContext, retryAuthOnFailure: false)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let err = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Pull failed: \(err)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["value"] as? [[String: Any]] else {
            return
        }

        // Fetch all local notes
        let descriptor = FetchDescriptor<StickyNote>()
        let localNotes = (try? modelContext.fetch(descriptor)) ?? []
        var localByRemoteId: [String: StickyNote] = [:]
        for note in localNotes {
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
            if pendingRemoteDeletes.contains(remoteId) || existingLocal?.isDeletedLocally == true {
                // Tombstone: do not resurrect; replay DELETE and drop the local stub.
                do {
                    try await performRemoteDelete(remoteId: remoteId, token: token)
                    if let existingLocal {
                        modelContext.delete(existingLocal)
                    }
                } catch {
                    print("Failed to replay delete for \(remoteId): \(error)")
                    if let existingLocal {
                        existingLocal.isDeletedLocally = true
                        existingLocal.syncStatus = .error
                    }
                }
                continue
            }

            if let localNote = existingLocal {
                // Note exists locally
                if localNote.changeKey == changeKey {
                    // Still cache `_Note` JSON so a later color-only upload can merge into it.
                    if let webNoteJSON {
                        localNote.webNoteJSON = webNoteJSON
                    }
                    continue
                }

                // Cloud has changes
                if localNote.syncStatus == .pendingUpload {
                    // Conflict Resolution:
                    // If cloud is newer, preserve cloud as primary and save local as copy
                    if let remoteModifiedDate, remoteModifiedDate > localNote.modifiedAt {
                        let copyNote = StickyNote(
                            color: localNote.noteColor,
                            content: localNote.plainTextContent
                        )
                        copyNote.attributedContentData = localNote.attributedContentData
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
                newNote.webNoteJSON = webNoteJSON
                modelContext.insert(newNote)
            }
        }

        try? modelContext.save()
    }

    // MARK: - Push Pending Local Notes

    private func pushPendingNotes(token: String, modelContext: ModelContext) async throws {
        try await pushPendingDeletes(token: token, modelContext: modelContext)

        let pendingStatus = SyncStatus.pendingUpload.rawValue
        let errorStatus = SyncStatus.error.rawValue
        let descriptor = FetchDescriptor<StickyNote>(
            predicate: #Predicate<StickyNote> { $0.syncStatusRaw == pendingStatus || $0.syncStatusRaw == errorStatus }
        )
        let pendingNotes = (try? modelContext.fetch(descriptor)) ?? []

        var uploadFailures = 0
        for note in pendingNotes {
            if note.isDeletedLocally { continue }
            do {
                try await uploadNote(note, token: token)
            } catch {
                print("Failed to push note \(note.id): \(error)")
                note.syncStatus = .error
                uploadFailures += 1
            }
        }

        try? modelContext.save()

        if uploadFailures > 0 {
            throw NSError(
                domain: "SyncEngine",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to upload \(uploadFailures) note(s)"]
            )
        }
    }

    // MARK: - Upload Single Note (Create or Update)

    func uploadNote(_ note: StickyNote, token: String, retryAuthOnFailure: Bool = true) async throws {
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

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
            }

            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) && retryAuthOnFailure {
                let newToken = try await authManager.refreshTokens()
                return try await uploadNote(note, token: newToken, retryAuthOnFailure: false)
            }

            // /me/notes requires ShortNotes.ReadWrite. Existing Mail.ReadWrite
            // sessions get 403/404; Graph also silently no-ops body writes on
            // PATCH /me/messages for non-draft notes. Recreate instead.
            if [400, 403, 404].contains(httpResponse.statusCode) {
                try await replaceRemoteNote(note, token: token, payloadData: jsonData, uploadedHTML: html)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                note.syncStatus = .error
                let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("Failed to update note (HTTP \(httpResponse.statusCode)): \(responseBody)")
                throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to update note (HTTP \(httpResponse.statusCode)): \(responseBody)"
                ])
            }

            try finishUpload(note, data: data, uploadedHTML: html, isCreate: false)
        } else {
            guard let notesURL = URL(string: "\(graphEndpoint)/me/notes") else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid notes URL"])
            }
            let (data, httpResponse) = try await sendJSON(url: notesURL, method: "POST", token: token, body: jsonData)

            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) && retryAuthOnFailure {
                let newToken = try await authManager.refreshTokens()
                return try await uploadNote(note, token: newToken, retryAuthOnFailure: false)
            }

            if [400, 403, 404].contains(httpResponse.statusCode) {
                try await createNoteInMailFolder(note, token: token, payloadData: jsonData, uploadedHTML: html)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                note.syncStatus = .error
                let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("Failed to create note (HTTP \(httpResponse.statusCode)): \(responseBody)")
                throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create note (HTTP \(httpResponse.statusCode)): \(responseBody)"
                ])
            }

            try finishUpload(note, data: data, uploadedHTML: html, isCreate: true)
        }
    }

    /// Mail.ReadWrite fallback: create a replacement note then delete the old one.
    /// PATCH /me/messages cannot persist body/subject on non-draft Outlook notes.
    private func replaceRemoteNote(_ note: StickyNote, token: String, payloadData: Data, uploadedHTML: String) async throws {
        let oldId = note.remoteId
        try await createNoteInMailFolder(note, token: token, payloadData: payloadData, uploadedHTML: uploadedHTML)
        if let oldId {
            do {
                try await performRemoteDelete(remoteId: oldId, token: token)
            } catch {
                print("Replacement created but failed to delete previous note \(oldId): \(error)")
            }
        }
    }

    private func createNoteInMailFolder(_ note: StickyNote, token: String, payloadData: Data, uploadedHTML: String) async throws {
        guard let url = URL(string: "\(graphEndpoint)/me/mailFolders/notes/messages") else {
            note.syncStatus = .error
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid notes folder URL"])
        }
        let mailPayload = Self.mailFolderCreatePayload(from: payloadData)
        let (data, httpResponse) = try await sendJSON(url: url, method: "POST", token: token, body: mailPayload)
        guard (200...299).contains(httpResponse.statusCode) else {
            note.syncStatus = .error
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create note (HTTP \(httpResponse.statusCode)): \(responseBody)"
            ])
        }
        try finishUpload(note, data: data, uploadedHTML: uploadedHTML, isCreate: true)
    }

    private func sendJSON(url: URL, method: String, token: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        return (data, httpResponse)
    }

    /// Never mark synced unless Graph returned a usable object. An empty 204/200
    /// or a 200 that echoes the old body is the false-success we must reject.
    private func finishUpload(_ note: StickyNote, data: Data, uploadedHTML: String, isCreate: Bool) throws {
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
            note.remoteId = newId
            note.changeKey = newChangeKey
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

        applyGraphTimestamps(json, to: note)
        note.webNoteJSON = NoteConverter.webNoteJSON(setting: note.noteColor, existing: note.webNoteJSON)
        note.syncStatus = .synced
        note.lastSyncedAt = Date()
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
        debounceTasks[noteID]?.cancel()

        debounceTasks[noteID] = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds debounce
            guard !Task.isCancelled else { return }

            guard authManager.isAuthenticated else { return }

            let descriptor = FetchDescriptor<StickyNote>(
                predicate: #Predicate<StickyNote> { $0.id == noteID }
            )
            guard let note = try? modelContext.fetch(descriptor).first else { return }

            do {
                self.state = .syncing
                let token = try await authManager.getValidAccessToken()
                try await uploadNote(note, token: token)
                try? modelContext.save()
                self.state = .idle
                self.lastSyncDate = Date()
            } catch {
                print("Debounced push error for note \(noteID): \(error)")
                note.syncStatus = .error
                try? modelContext.save()
                self.state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Delete Note Remotely

    func deleteRemoteNote(remoteId: String) {
        pendingRemoteDeletes.insert(remoteId)
        Task {
            guard authManager.isAuthenticated else {
                self.state = .error("Delete pending until signed in")
                return
            }
            do {
                let token = try await authManager.getValidAccessToken()
                try await performRemoteDelete(remoteId: remoteId, token: token)
            } catch {
                print("Failed to delete remote note \(remoteId): \(error)")
                self.state = .error(error.localizedDescription)
            }
        }
    }

    private func pushPendingDeletes(token: String, modelContext: ModelContext) async throws {
        let descriptor = FetchDescriptor<StickyNote>()
        let localNotes = (try? modelContext.fetch(descriptor)) ?? []

        var ids = pendingRemoteDeletes
        for note in localNotes where note.isDeletedLocally {
            if let remoteId = note.remoteId {
                ids.insert(remoteId)
            } else {
                modelContext.delete(note)
            }
        }

        for remoteId in ids {
            do {
                try await performRemoteDelete(remoteId: remoteId, token: token)
                for note in localNotes where note.remoteId == remoteId {
                    if note.isDeletedLocally {
                        modelContext.delete(note)
                    }
                }
            } catch {
                print("Failed to push pending delete \(remoteId): \(error)")
                for note in localNotes where note.remoteId == remoteId {
                    note.isDeletedLocally = true
                    note.syncStatus = .error
                }
            }
        }
    }

    private func performRemoteDelete(remoteId: String, token: String, retryAuthOnFailure: Bool = true) async throws {
        guard let url = graphItemURL(collection: "me/messages", id: remoteId) else {
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid delete URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) && retryAuthOnFailure {
            let newToken = try await authManager.refreshTokens()
            return try await performRemoteDelete(remoteId: remoteId, token: newToken, retryAuthOnFailure: false)
        }

        if httpResponse.statusCode == 404 {
            pendingRemoteDeletes.remove(remoteId)
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "SyncEngine", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to delete note (HTTP \(httpResponse.statusCode)): \(responseBody)"
            ])
        }

        pendingRemoteDeletes.remove(remoteId)
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

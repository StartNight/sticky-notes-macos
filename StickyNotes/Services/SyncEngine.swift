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
            case .idle: return "Synced"
            case .syncing: return "Syncing..."
            case .error(let msg): return "Error: \(msg)"
            case .offline: return "Offline"
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

    private func pullNotes(token: String, modelContext: ModelContext) async throws {
        let urlString = "\(graphEndpoint)/me/mailFolders/notes/messages?$top=100&$select=id,changeKey,subject,body,createdDateTime,lastModifiedDateTime,singleValueExtendedProperties"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        if httpResponse.statusCode == 401 {
            // Re-attempt with refreshed token
            let newToken = try await authManager.refreshTokens()
            return try await pullNotes(token: newToken, modelContext: modelContext)
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

            let remoteModifiedDateStr = msg["lastModifiedDateTime"] as? String
            let remoteModifiedDate = remoteModifiedDateStr.flatMap(parseDate) ?? Date()

            let remoteCreatedDateStr = msg["createdDateTime"] as? String
            let remoteCreatedDate = remoteCreatedDateStr.flatMap(parseDate) ?? Date()

            // Extract color if available
            var noteColor = NoteColor.yellow
            if let props = msg["singleValueExtendedProperties"] as? [[String: Any]] {
                for prop in props {
                    if let propId = prop["id"] as? String, propId.contains("0x35E0"),
                       let valStr = prop["value"] as? String, let code = Int(valStr) {
                        noteColor = NoteConverter.noteColor(fromOutlookCode: code)
                    }
                }
            }

            if let localNote = localByRemoteId[remoteId] {
                // Note exists locally
                if localNote.changeKey == changeKey {
                    // No remote changes
                    continue
                }

                // Cloud has changes
                if localNote.syncStatus == .pendingUpload {
                    // Conflict Resolution:
                    // If cloud is newer, preserve cloud as primary and save local as copy
                    if remoteModifiedDate > localNote.modifiedAt {
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
                        localNote.changeKey = changeKey
                        localNote.modifiedAt = remoteModifiedDate
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
                    localNote.changeKey = changeKey
                    localNote.modifiedAt = remoteModifiedDate
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
                newNote.createdAt = remoteCreatedDate
                newNote.modifiedAt = remoteModifiedDate
                modelContext.insert(newNote)
            }
        }

        try? modelContext.save()
    }

    // MARK: - Push Pending Local Notes

    private func pushPendingNotes(token: String, modelContext: ModelContext) async throws {
        let pendingStatus = SyncStatus.pendingUpload.rawValue
        let descriptor = FetchDescriptor<StickyNote>(
            predicate: #Predicate<StickyNote> { $0.syncStatusRaw == pendingStatus }
        )
        let pendingNotes = (try? modelContext.fetch(descriptor)) ?? []

        for note in pendingNotes {
            try await uploadNote(note, token: token)
        }

        try? modelContext.save()
    }

    // MARK: - Upload Single Note (Create or Update)

    func uploadNote(_ note: StickyNote, token: String) async throws {
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

        let payload: [String: Any] = [
            "subject": note.title,
            "body": [
                "contentType": "html",
                "content": html
            ],
            "singleValueExtendedProperties": [
                [
                    "id": "Integer 0x35E0",
                    "value": "\(NoteConverter.outlookColorCode(for: note.noteColor))"
                ]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        if let remoteId = note.remoteId {
            // PATCH existing message
            guard let url = URL(string: "\(graphEndpoint)/me/messages/\(remoteId)") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to update note"])
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newChangeKey = json["changeKey"] as? String {
                note.changeKey = newChangeKey
            }
            note.syncStatus = .synced
            note.lastSyncedAt = Date()
        } else {
            // POST new message to notes folder
            guard let url = URL(string: "\(graphEndpoint)/me/mailFolders/notes/messages") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create note"])
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newId = json["id"] as? String,
               let newChangeKey = json["changeKey"] as? String {
                note.remoteId = newId
                note.changeKey = newChangeKey
            }
            note.syncStatus = .synced
            note.lastSyncedAt = Date()
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
                let token = try await authManager.getValidAccessToken()
                try await uploadNote(note, token: token)
                try? modelContext.save()
            } catch {
                print("Debounced push error for note \(noteID): \(error)")
                note.syncStatus = .error
                try? modelContext.save()
            }
        }
    }

    // MARK: - Delete Note Remotely

    func deleteRemoteNote(remoteId: String) {
        Task {
            guard authManager.isAuthenticated else { return }
            do {
                let token = try await authManager.getValidAccessToken()
                guard let url = URL(string: "\(graphEndpoint)/me/messages/\(remoteId)") else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                _ = try await URLSession.shared.data(for: request)
            } catch {
                print("Failed to delete remote note \(remoteId): \(error)")
            }
        }
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

    private func parseDate(_ string: String) -> Date? {
        Self.isoFormatterFractional.date(from: string) ?? Self.isoFormatterStandard.date(from: string)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let requestModelContextSync = Notification.Name("requestModelContextSync")
}

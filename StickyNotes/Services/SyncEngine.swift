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

        var statusColor: Color {
            switch self {
            case .idle: return .green
            case .syncing: return .blue
            case .error: return .orange
            case .offline: return .secondary
            }
        }
    }

    // MARK: - State
    var state: EngineState = .idle
    var incompleteTaskCount = 0
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

    private let colorLedger: ColorEditLedger
    private let graphEndpoint = "https://graph.microsoft.com/v1.0"
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var debounceTokens: [UUID: UUID] = [:]
    private(set) var activeScheduledPushCount = 0
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
        guard !note.recoveryPaused, note.recoveryPendingDeleteID == nil else { throw syncError(-40, "此便笺已暂停，需在待核对清单明确恢复。") }
        guard !note.hasCorruptRecoveryJournal else { throw syncError(-41, "恢复日志无法解析，已保留原始数据。") }
        guard !note.hasCorruptSyncJournal else { throw syncError(-36, "同步清理记录无法解析，已保留数据并阻止自动写入。") }
        guard note.pendingCreateOperationID == nil else {
            throw syncError(-30, "创建结果待确认：内容已保留，已阻止自动重建；请先核对云端对象，勿盲目重试。")
        }
    }
    /// Both deletion UIs must call this BEFORE removing a model or sending a DELETE.
    func prepareForDeletion(_ note: StickyNote, modelContext: ModelContext) throws {
        debounceTasks[note.id]?.cancel()
        debounceTasks.removeValue(forKey: note.id)
        debounceTokens.removeValue(forKey: note.id)
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
    /// Cloud-new notes not imported in the latest pull because some local note has an unreadable journal.
    private(set) var skippedCloudCreateCount = 0
    private var lastSyncKey: String { "ms_last_sync_timestamp.account." + (authManager.accountID ?? "unverified") }

    struct Scope {
        let accountID: String
        let generation: UUID
    }
    private func currentScope() throws -> Scope {
        guard authManager.isAuthenticated, authManager.isIdentityVerified, let id = authManager.accountID, !id.isEmpty else {
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


    init(authManager: any SyncAuthProviding = AuthManager.shared, debounceNanoseconds: UInt64 = 1_500_000_000,
         colorLedger: ColorEditLedger = .shared) {
        self.authManager = authManager
        self.colorLedger = colorLedger
        self.debounceNanoseconds = debounceNanoseconds
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

        guard !fullSyncRunning else { return }
        fullSyncRunning = true
        defer { fullSyncRunning = false }
        self.state = .syncing
        skippedCloudCreateCount = 0

        do {
            let generation = authManager.sessionGeneration
            _ = try await authManager.ensureAccountID()
            guard generation == authManager.sessionGeneration else { throw CancellationError() }
            let scope = try currentScope()
            let token = try await authManager.getValidAccessToken()
            try validate(scope)
            // 1. Pull remote changes
            try await pullNotes(token: token, modelContext: modelContext, scope: scope)
            // 2. Push pending local changes
            try await pushPendingNotes(token: token, modelContext: modelContext, scope: scope)
            _ = try await pushPendingDeletes(token: token, modelContext: modelContext, scope: scope)
            try validate(scope)
            try ensureNoPendingWork(modelContext: modelContext, scope: scope)

            self.incompleteTaskCount = 0
            self.state = .idle
            self.lastSyncDate = Date()
        } catch is CancellationError {
            return
        } catch {
            print("Sync failed: code=\((error as NSError).code)")
            let scope = try? currentScope()
            incompleteTaskCount = max(1, scope.map { problemCount(modelContext: modelContext, scope: $0) } ?? 1)
            self.state = .error("尚有 \(incompleteTaskCount) 项未完成：" + error.localizedDescription)
        }
    }

    // MARK: - Pull Remote Notes

    private func pullNotes(token: String, modelContext: ModelContext, scope: Scope, retryAuthOnFailure: Bool = true) async throws {
        let lidId = NoteConverter.pidLidNoteColorPropertyId
        let webId = NoteConverter.webNoteJSONPropertyId
        let iconId = NoteConverter.pidTagIconIndexPropertyId
        let expandClause = "singleValueExtendedProperties($filter=id eq '\(lidId)' or id eq '\(webId)' or id eq '\(iconId)')"
        let encodedExpand = expandClause.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? expandClause
        let urlString = "\(graphEndpoint)/me/mailFolders/notes/messages?$top=100&$orderby=lastModifiedDateTime%20desc&$select=id,changeKey,subject,body,createdDateTime,lastModifiedDateTime&$expand=\(encodedExpand)"
        guard let firstURL = URL(string: urlString) else { return }
        var pageURL: URL? = firstURL
        var activeToken = token
        var didRetryAuth = !retryAuthOnFailure
        var messages: [[String: Any]] = []

        // Graph caps page size and returns @odata.nextLink. Process every page before applying
        // the pull so notes beyond the first 100 are imported and conflict decisions see a full set.
        while let url = pageURL {
            try validate(scope)
            guard url.scheme == "https", url.host == "graph.microsoft.com" else {
                throw syncError(-22, "Graph 返回了无效的分页地址，已停止同步。")
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let (data, response) = try await scopedData(for: request, scope: scope)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw syncError(-1, "Invalid server response")
            }
            if httpResponse.statusCode == 401 {
                guard !didRetryAuth else {
                    throw NSError(domain: "SyncEngine", code: 401, userInfo: [NSLocalizedDescriptionKey: "Pull failed: unauthorized"])
                }
                activeToken = try await refreshedToken(scope: scope)
                didRetryAuth = true
                continue // Retry this page once with the refreshed token.
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw NSError(domain: "SyncEngine", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Pull failed: HTTP \(httpResponse.statusCode)"])
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pageMessages = json["value"] as? [[String: Any]] else {
                throw syncError(-23, "Graph 返回了无法解析的便笺列表。")
            }
            messages.append(contentsOf: pageMessages)
            if let next = json["@odata.nextLink"] as? String {
                guard let nextURL = URL(string: next) else {
                    throw syncError(-22, "Graph 返回了无效的分页地址，已停止同步。")
                }
                pageURL = nextURL
            } else {
                pageURL = nil
            }
        }

        // Fetch all local notes
        let descriptor = FetchDescriptor<StickyNote>()
        let localNotes = try modelContext.fetch(descriptor)
        // A note whose cleanup journal is unreadable is isolated individually (never uploaded/deleted/overwritten).
        // Because its retired-ID list is unknown, creating NEW local notes from the cloud is paused so a retired
        // object cannot be resurrected; updates to other known notes and all unrelated uploads continue.
        let journalIsolated = localNotes.contains { $0.ownerAccountID == scope.accountID && $0.hasCorruptSyncJournal }
        var skippedCloudCreates = 0
        var retiredIDs: Set<String> = []
        var localByRemoteId: [String: StickyNote] = [:]
        for note in localNotes where note.ownerAccountID == scope.accountID {
            retiredIDs.formUnion(note.pendingCleanupRemoteIDs)
            if let rId = note.remoteId {
                localByRemoteId[rId] = note
            }
        }

        var seenRemoteIDs: Set<String> = []
        for msg in messages {
            guard let remoteId = msg["id"] as? String,
                  let changeKey = msg["changeKey"] as? String else {
                continue
            }
            seenRemoteIDs.insert(remoteId)

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
            let colorProps = (msg["singleValueExtendedProperties"] as? [[String: Any]]) ?? []

            let existingLocal = localByRemoteId[remoteId]
            if (pendingRemoteDeletes[scope.accountID] ?? []).contains(remoteId) ||
                existingLocal?.isDeletedLocally == true || retiredIDs.contains(remoteId) {
                // Never resurrect tombstones/retired objects. Durable delete replay is centralized
                // in pushPendingDeletes so failures propagate to the overall sync result.
                continue
            }

            if let localNote = existingLocal {
                if localNote.hasCorruptSyncJournal { continue }
                // An unresolved POST may have committed. Keep its original content/metadata frozen
                // for explicit reconciliation; don't turn it into an auto-uploadable conflict copy.
                if localNote.pendingCreateOperationID != nil || localNote.recoveryPaused || localNote.recoveryPendingDeleteID != nil || localNote.hasCorruptRecoveryJournal { continue }
                // Note exists locally
                ColorDiagnostics.pull(event: localNote.changeKey == changeKey ? "same-changeKey" : "changed",
                                      remoteID: remoteId, local: localNote.noteColor, props: colorProps, resolved: noteColor)
                if localNote.changeKey == changeKey {
                    // Still cache `_Note` JSON so a later color-only upload can merge into it.
                    if let webNoteJSON {
                        localNote.webNoteJSON = webNoteJSON
                    }
                    if localNote.syncStatus == .synced && !colorLedger.isDirty(localNote.id) && localNote.noteColor != noteColor {
                        localNote.noteColor = noteColor
                    }
                    continue
                }

                // A recovered binding must never turn an external conflict into an automatic POST.
                if localNote.recoveryBlocksAutomaticRecreate &&
                    (localNote.syncStatus == .pendingUpload || localNote.syncStatus == .error) {
                    localNote.recoveryPaused = true
                    localNote.syncStatus = .error
                    addAudit(localNote, action: "pause-remote-changed-after-recovery",
                             reason: "恢复关联后远端版本变化，保全本地内容并等待重新核对，不自动创建冲突副本。", scope: scope)
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
                        // 网页原色保护：副本是新的云端对象。只有用户在本地选过的颜色才会写入；
                        // 否则只搬运缓存的云端 `_Note`（没有就不写）。主便笺随后取云端颜色，因此它自己的 dirty 标记不再适用。
                        let wasDirty = colorLedger.isDirty(localNote.id)
                        if wasDirty { colorLedger.markDirty(copyNote.id) } else { colorLedger.markCarry(copyNote.id) }
                        colorLedger.clearDirty(localNote.id)
                        ColorDiagnostics.guardDecision(path: "conflict-copy", remoteID: remoteId, dirty: wasDirty,
                                                       policy: wasDirty ? "writeLocal" : "carryCached")

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
                    // 本地无未提交改动，用云端覆盖（云端颜色胜出；清除本地 dirty）
                    colorLedger.clearDirty(localNote.id)
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
                if journalIsolated { skippedCloudCreates += 1; continue }
                // New note from cloud
                ColorDiagnostics.pull(event: "new-from-cloud", remoteID: remoteId, local: nil, props: colorProps, resolved: noteColor)
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

        // Reconcile cloud deletions: any local note in this account scope that was synced
        // to a remoteId but is absent from the full remote list has been deleted in the cloud.
        for localNote in localNotes where localNote.ownerAccountID == scope.accountID {
            guard let rId = localNote.remoteId, !rId.isEmpty, !seenRemoteIDs.contains(rId) else { continue }
            guard localNote.syncStatus == .synced else { continue }
            if localNote.isDeleted || localNote.isDeletedLocally { continue }
            if localNote.hasCorruptSyncJournal || localNote.hasCorruptRecoveryJournal { continue }
            if localNote.pendingCreateOperationID != nil || localNote.recoveryPaused ||
                localNote.recoveryPendingDeleteID != nil || localNote.hasRecoveryHistory ||
                !localNote.pendingCleanupRemoteIDs.isEmpty { continue }
            if uploadingNoteIDs.contains(localNote.id) { continue }
            debounceTasks[localNote.id]?.cancel()
            debounceTasks.removeValue(forKey: localNote.id)
            debounceTokens.removeValue(forKey: localNote.id)
            colorLedger.clearDirty(localNote.id)
            colorLedger.clearCarry(localNote.id)
            modelContext.delete(localNote)
        }

        try modelContext.save()
        skippedCloudCreateCount = skippedCloudCreates
    }

    // MARK: - Push Pending Local Notes

    private func healIncompleteSubstrateNotes(in modelContext: ModelContext, scope: Scope) {
        let descriptor = FetchDescriptor<StickyNote>()
        guard let notes = try? modelContext.fetch(descriptor) else { return }
        var hasChanges = false
        for note in notes where note.ownerAccountID == scope.accountID {
            if note.isDeletedLocally || note.isDeleted || note.recoveryPaused || note.recoveryPendingDeleteID != nil || note.hasCorruptSyncJournal { continue }
            if note.remoteId != nil && NoteConverter.isLegacyMacAuthoredIncompleteNoteJSON(note.webNoteJSON) {
                note.webNoteJSON = NoteConverter.webNoteJSON(
                    setting: note.noteColor,
                    existing: note.webNoteJSON,
                    plainText: note.plainTextContent,
                    localID: note.id,
                    modifiedAt: note.modifiedAt
                )
                colorLedger.markDirty(note.id)
                note.syncStatus = .pendingUpload
                hasChanges = true
            }
        }
        if hasChanges {
            try? modelContext.save()
        }
    }

    private func pushPendingNotes(token: String, modelContext: ModelContext, scope: Scope) async throws {
        healIncompleteSubstrateNotes(in: modelContext, scope: scope)
        let deleteFailures = try await pushPendingDeletes(token: token, modelContext: modelContext, scope: scope)

        let pendingStatus = SyncStatus.pendingUpload.rawValue
        let errorStatus = SyncStatus.error.rawValue
        let descriptor = FetchDescriptor<StickyNote>(
            predicate: #Predicate<StickyNote> { $0.syncStatusRaw == pendingStatus || $0.syncStatusRaw == errorStatus }
        )
        let pendingNotes = (try? modelContext.fetch(descriptor)) ?? []

        var uploadFailures = 0
        for note in pendingNotes where note.ownerAccountID == scope.accountID {
            if note.isDeletedLocally || note.recoveryPaused || note.recoveryPendingDeleteID != nil || note.hasCorruptSyncJournal { continue }
            if isUntouchedBlankNewNote(note) { continue }
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

        if uploadFailures + deleteFailures > 0 {
            throw NSError(
                domain: "SyncEngine",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "仍有 \(uploadFailures + deleteFailures) 项上传、删除或待核对操作未完成。"]
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

        // 网页原色保护：只有用户在本地选过的颜色（或没有云端对应物的全新对象）才写颜色属性。
        // 其余情况一律不改网页原色。
        let plan = colorPlan(for: note)
        var payload: [String: Any] = [
            "subject": subject,
            "body": [
                "contentType": "html",
                "content": html
            ]
        ]
        let colorProps = Self.colorProperties(
            for: plan,
            color: note.noteColor,
            cachedWebJSON: note.webNoteJSON,
            plainText: note.plainTextContent,
            localID: note.id,
            modifiedAt: note.modifiedAt
        )
        if !colorProps.isEmpty { payload["singleValueExtendedProperties"] = colorProps }
        ColorDiagnostics.guardDecision(path: note.remoteId == nil ? "create" : "patch", remoteID: note.remoteId,
                                       dirty: colorLedger.isDirty(note.id), policy: plan.policy.rawValue)

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        ColorDiagnostics.upload(event: note.remoteId == nil ? "create" : "patch", remoteID: note.remoteId, local: snapshot.color, sent: plan.sentToken)

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

            if httpResponse.statusCode == 401 && retryAuthOnFailure {
                let newToken = try await refreshedToken(scope: scope)
                return try await uploadLocked(note, token: newToken, retryAuthOnFailure: false, scope: scope)
            }

            // /me/notes requires ShortNotes.ReadWrite. Existing Mail.ReadWrite
            // sessions get 403/404; Graph also silently no-ops body writes on
            // PATCH /me/messages for non-draft notes. Recreate instead.
            if [400, 403, 404].contains(httpResponse.statusCode) {
                guard !note.recoveryBlocksAutomaticRecreate else { throw syncError(-42, "关联对象更新失败；已禁止自动重建，请在待核对页明确确认。") }
                try await replaceRemoteNote(note, token: token, scope: scope, payloadData: jsonData, uploadedHTML: html, snapshot: snapshot, plan: plan)
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

            try finishUpload(note, data: data, uploadedHTML: html, isCreate: false, snapshot: snapshot, plan: plan)
            // A verified 2xx PATCH proves the recovered binding is writable: the "no automatic recreate" guard
            // has served its purpose (S3-A). It stays on only while PATCH keeps failing.
            if note.recoveryBlocksAutomaticRecreate && note.syncStatus == .synced {
                note.recoveryBlocksAutomaticRecreate = false
                try saveDurably(note)
            }
        } else {
            guard let notesURL = URL(string: "\(graphEndpoint)/me/notes") else {
                note.syncStatus = .error
                throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid notes URL"])
            }
            let (data, httpResponse) = try await sendCreate(note, url: notesURL, token: token, body: jsonData, scope: scope)

            if httpResponse.statusCode == 401 && retryAuthOnFailure {
                let newToken = try await refreshedToken(scope: scope)
                return try await uploadLocked(note, token: newToken, retryAuthOnFailure: false, scope: scope)
            }

            if [400, 403, 404].contains(httpResponse.statusCode) {
                try await createNoteInMailFolder(note, token: token, scope: scope, payloadData: jsonData, uploadedHTML: html, snapshot: snapshot, plan: plan)
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

            try finishUpload(note, data: data, uploadedHTML: html, isCreate: true, snapshot: snapshot, plan: plan)
        }
    }

    /// Mail.ReadWrite fallback: create a replacement note then delete the old one.
    /// PATCH /me/messages cannot persist body/subject on non-draft Outlook notes.
    private func replaceRemoteNote(_ note: StickyNote, token: String, scope: Scope, payloadData: Data, uploadedHTML: String, snapshot: UploadSnapshot, plan suppliedPlan: ColorPlan) async throws {
        try requireUploadable(note, scope: scope)
        let oldId = note.remoteId
        var plan = suppliedPlan
        var payloadData = payloadData
        if plan.policy != .writeLocal, let oldId {
            // 用户没有改过颜色：替换对象必须把旧对象自己的颜色属性原封不动搬过来（此刻现读），绝不用本地（可能解错的）颜色。
            let carried = await fetchServerColorProperties(remoteId: oldId, token: token, scope: scope)
            try validate(scope)
            if let carried {
                payloadData = Self.replacingColorProperties(in: payloadData, with: carried.properties)
                plan = ColorPlan(policy: .carryServer, carriedWebJSON: carried.webJSON)
                ColorDiagnostics.guardDecision(path: "replace", remoteID: oldId, dirty: false, policy: "carryServer",
                                               detail: carried.properties.isEmpty ? "server-has-no-colour" : "props=\(carried.properties.count)")
            } else {
                // 读不到旧对象：退回原样搬运缓存的云端 `_Note`，没有缓存就不写。
                var cachedProps: [[String: Any]] = []
                if let cached = note.webNoteJSON { cachedProps = [["id": NoteConverter.webNoteJSONPropertyId, "value": cached]] }
                payloadData = Self.replacingColorProperties(in: payloadData, with: cachedProps)
                plan = ColorPlan(policy: .carryCached, carriedWebJSON: nil)
                ColorDiagnostics.guardDecision(path: "replace", remoteID: oldId, dirty: false, policy: "carryCached",
                                               detail: note.webNoteJSON == nil ? "read-failed-no-cache" : "read-failed-cached_Note")
            }
        } else {
            ColorDiagnostics.guardDecision(path: "replace", remoteID: oldId, dirty: true, policy: "writeLocal")
        }
        try await createNoteInMailFolder(note, token: token, scope: scope, payloadData: payloadData, uploadedHTML: uploadedHTML, snapshot: snapshot, plan: plan)
        if let oldId {
            // finishUpload durably journaled oldId before it replaced remoteId.
            try await performRemoteDelete(remoteId: oldId, token: token, scope: scope)
            note.pendingCleanupRemoteIDs.removeAll { $0 == oldId }
            try saveDurably(note)
        }
    }

    private func createNoteInMailFolder(_ note: StickyNote, token: String, scope: Scope, payloadData: Data, uploadedHTML: String, snapshot: UploadSnapshot, plan: ColorPlan) async throws {
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
        try finishUpload(note, data: data, uploadedHTML: uploadedHTML, isCreate: true, snapshot: snapshot, plan: plan)
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
    private func finishUpload(_ note: StickyNote, data: Data, uploadedHTML: String, isCreate: Bool, snapshot: UploadSnapshot, plan: ColorPlan) throws {
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

        ColorDiagnostics.upload(event: isCreate ? "create-ok" : "patch-ok", remoteID: note.remoteId, local: snapshot.color, sent: plan.sentToken)
        let unchanged = snapshot.matches(note) && !note.isDeletedLocally
        if unchanged { applyGraphTimestamps(json, to: note) }
        // 只缓存实际发出去的内容。没写过的颜色不能当成「云端已是这个色」；
        // 从云端原样搬来的颜色，继续保留云端自己的 `_Note`。
        switch plan.policy {
        case .writeLocal:
            note.webNoteJSON = NoteConverter.webNoteJSON(
                setting: snapshot.color,
                existing: note.webNoteJSON,
                plainText: snapshot.text,
                localID: note.id,
                modifiedAt: snapshot.modified
            )
            // 若上传过程中用户又改了颜色，则保持 dirty。
            if snapshot.color == note.noteColor { colorLedger.clearDirty(note.id) }
        case .carryServer:
            if let web = plan.carriedWebJSON { note.webNoteJSON = web }
        case .omit, .carryCached:
            break
        }
        colorLedger.clearCarry(note.id)
        note.syncStatus = unchanged ? .synced : .pendingUpload
        note.lastSyncedAt = Date()
        try saveDurably(note)
    }

    // MARK: - 网页原色保护

    fileprivate enum ColorWritePolicy: String {
        /// 写入本地颜色（`_Note` + 0x8B00）：用户选过，或没有云端对应物的全新对象。
        case writeLocal
        /// 不带任何颜色属性（PATCH 已有对象且用户未改色）。
        case omit
        /// 新对象不得自行推断颜色：原样搬运缓存的云端 `_Note`，没有就不写。
        case carryCached
        /// 替换后的新对象：搬运刚从云端读到的旧对象原始颜色属性。
        case carryServer
    }

    fileprivate struct ColorPlan {
        var policy: ColorWritePolicy
        var carriedWebJSON: String? = nil
        var sentToken: String {
            switch policy {
            case .writeLocal: return "local"
            case .omit: return "none"
            case .carryCached: return "cached_Note"
            case .carryServer: return "server_copy"
            }
        }
    }

    fileprivate func colorPlan(for note: StickyNote) -> ColorPlan {
        if colorLedger.isDirty(note.id) { return ColorPlan(policy: .writeLocal) }
        if note.remoteId == nil {
            return ColorPlan(policy: colorLedger.isCarry(note.id) ? .carryCached : .writeLocal)
        }
        if NoteConverter.isLegacyMacAuthoredIncompleteNoteJSON(note.webNoteJSON) {
            return ColorPlan(policy: .writeLocal)
        }
        return ColorPlan(policy: .omit)
    }

    fileprivate static func colorProperties(
        for plan: ColorPlan,
        color: NoteColor,
        cachedWebJSON: String?,
        plainText: String? = nil,
        localID: UUID? = nil,
        modifiedAt: Date = Date()
    ) -> [[String: Any]] {
        switch plan.policy {
        case .writeLocal:
            return NoteConverter.graphColorExtendedProperties(
                for: color,
                existingWebNoteJSON: cachedWebJSON,
                plainText: plainText,
                localID: localID,
                modifiedAt: modifiedAt
            )
        case .omit, .carryServer:
            return []
        case .carryCached:
            guard let cachedWebJSON else { return [] }
            return [["id": NoteConverter.webNoteJSONPropertyId, "value": cachedWebJSON]]
        }
    }

    /// 替换（绝不合并）已编码 payload 里的颜色属性。
    fileprivate static func replacingColorProperties(in data: Data, with properties: [[String: Any]]) -> Data {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        var props = obj["singleValueExtendedProperties"] as? [[String: Any]] ?? []
        props.removeAll { prop in
            guard let id = prop["id"] as? String else { return false }
            return NoteConverter.isPidLidNoteColorProperty(id) ||
                   NoteConverter.isWebNoteJSONProperty(id) ||
                   NoteConverter.isPidTagIconIndexProperty(id)
        }
        props.append(contentsOf: properties)
        if props.isEmpty { obj.removeValue(forKey: "singleValueExtendedProperties") } else { obj["singleValueExtendedProperties"] = props }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }

    /// 只读：云端对象自己的颜色属性，值原封不动。`nil` 表示读失败（不得猜测）；空列表表示云端对象本来就没有颜色属性。
    fileprivate func fetchServerColorProperties(remoteId: String, token: String, scope: Scope) async -> (properties: [[String: Any]], webJSON: String?)? {
        let lidId = NoteConverter.pidLidNoteColorPropertyId
        let webId = NoteConverter.webNoteJSONPropertyId
        let iconId = NoteConverter.pidTagIconIndexPropertyId
        let clause = "singleValueExtendedProperties($filter=id eq '\(lidId)' or id eq '\(webId)' or id eq '\(iconId)')"
        guard let base = graphItemURL(collection: "me/messages", id: remoteId),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        // Include `body` in $select so Exchange reads the full item rather than truncating `_Note` at 255 chars.
        components.queryItems = [URLQueryItem(name: "$select", value: "id,body"), URLQueryItem(name: "$expand", value: clause)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await scopedData(for: request, scope: scope),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["id"] as? String == remoteId else { return nil }
        var out: [[String: Any]] = []
        var web: String?
        for prop in (json["singleValueExtendedProperties"] as? [[String: Any]]) ?? [] {
            guard let id = prop["id"] as? String, let value = prop["value"] as? String else { continue }
            if NoteConverter.isWebNoteJSONProperty(id) { out.append(["id": webId, "value": value]); web = value }
            else if NoteConverter.isPidLidNoteColorProperty(id) { out.append(["id": lidId, "value": value]) }
            else if NoteConverter.isPidTagIconIndexProperty(id) { out.append(["id": iconId, "value": value]) }
        }
        return (out, web)
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

    func isUntouchedBlankNewNote(_ note: StickyNote) -> Bool {
        note.remoteId == nil &&
        note.plainTextContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        note.audioRecordings.isEmpty &&
        !colorLedger.isDirty(note.id)
    }

    private func applyGraphTimestamps(_ json: [String: Any], to note: StickyNote) {
        let remoteModified = Self.plausibleGraphDate(json["lastModifiedDateTime"] as? String)
        note.modifiedAt = StickyNote.resolvedModifiedAt(local: note.modifiedAt, remote: remoteModified)
        if note.createdAt == Date.distantPast, let created = Self.plausibleGraphDate(json["createdDateTime"] as? String) {
            note.createdAt = created
        }
    }

    // MARK: - Debounced Push

    func scheduleDebouncedPush(for noteID: UUID, in modelContext: ModelContext) {
        // Capture login generation when scheduled, not after the debounce delay.
        guard let scope = try? currentScope() else { return }
        // This dictionary contains WAITING delays only, never a dispatched CREATE task.
        debounceTasks[noteID]?.cancel()
        let debounceToken = UUID()
        debounceTokens[noteID] = debounceToken
        debounceTasks[noteID] = Task {
            try? await Task.sleep(nanoseconds: debounceNanoseconds) // 1.5 seconds debounce
            guard !Task.isCancelled, debounceTokens[noteID] == debounceToken else { return }
            debounceTasks.removeValue(forKey: noteID)
            debounceTokens.removeValue(forKey: noteID)
            activeScheduledPushCount += 1
            defer { activeScheduledPushCount -= 1 }
            // The in-flight operation now owns its lifecycle. Further typing queues a new delay,
            // not cancellation of this non-idempotent request.
            guard authManager.isAuthenticated else { return }

            let descriptor = FetchDescriptor<StickyNote>(
                predicate: #Predicate<StickyNote> { $0.id == noteID }
            )
            guard let note = try? modelContext.fetch(descriptor).first,
                  note.ownerAccountID == scope.accountID, !note.isDeletedLocally, !note.recoveryPaused else { return }

            do {
                try validate(scope)
                self.state = .syncing
                let token = try await authManager.getValidAccessToken()
                try validate(scope)
                try await uploadNote(note, token: token, scope: scope)
                _ = try await pushPendingDeletes(token: token, modelContext: modelContext, scope: scope)
                try modelContext.save()
                try ensureNoPendingWork(modelContext: modelContext, scope: scope)
                incompleteTaskCount = 0
                self.state = .idle
                self.lastSyncDate = Date()
            } catch is CancellationError {
                return
            } catch {
                print("Debounced push failed: code=\((error as NSError).code)")
                if !note.isDeleted && !note.isDeletedLocally &&
                    !(note.syncStatus == .synced && !note.pendingCleanupRemoteIDs.isEmpty) { note.syncStatus = .error }
                try? modelContext.save()
                incompleteTaskCount = max(1, problemCount(modelContext: modelContext, scope: scope))
                self.state = .error("尚有 \(incompleteTaskCount) 项未完成：" + error.localizedDescription)
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

    private func isProblem(_ note: StickyNote) -> Bool {
        if note.pendingCreateOperationID != nil || note.recoveryPendingDeleteID != nil ||
            !note.recoveryRetainedRemoteIDs.isEmpty || note.hasCorruptSyncJournal || note.hasCorruptRecoveryJournal { return true }
        if note.recoveryPaused { return note.syncStatus == .error } // automatic conflict pause remains unresolved
        if !note.isDeletedLocally && note.pendingCleanupRemoteIDs.isEmpty && isUntouchedBlankNewNote(note) {
            return false
        }
        return note.isDeletedLocally || note.syncStatus != .synced || !note.pendingCleanupRemoteIDs.isEmpty
    }
    private func problemCount(modelContext: ModelContext, scope: Scope) -> Int {
        let notes = (try? modelContext.fetch(FetchDescriptor<StickyNote>())) ?? []
        return notes.filter { $0.ownerAccountID == scope.accountID && isProblem($0) }.count
    }
    private func ensureNoPendingWork(modelContext: ModelContext, scope: Scope) throws {
        try validate(scope)
        let count = problemCount(modelContext: modelContext, scope: scope)
        incompleteTaskCount = count
        if count > 0 {
            let corrupt = ((try? modelContext.fetch(FetchDescriptor<StickyNote>())) ?? [])
                .filter { $0.ownerAccountID == scope.accountID && $0.hasCorruptSyncJournal }.count
            var message = "仍有 \(count) 项本地改动、删除或恢复问题未完成。"
            if corrupt > 0 { message += "其中 \(corrupt) 条便笺的同步日志损坏，已单独隔离（不上传、不删除、不覆盖），其余便笺照常同步。" }
            if corrupt > 0 && skippedCloudCreateCount > 0 { message += "另有 \(skippedCloudCreateCount) 条云端新便笺暂未导入。" }
            throw syncError(-34, message)
        }
    }

    private func pushPendingDeletes(token: String, modelContext: ModelContext, scope: Scope) async throws -> Int {
        try validate(scope)
        let accountNotes = try modelContext.fetch(FetchDescriptor<StickyNote>()).filter { $0.ownerAccountID == scope.accountID }
        // Only the records with an unreadable journal are isolated; they are neither deleted nor trusted.
        let localNotes = accountNotes.filter { !$0.hasCorruptSyncJournal }
        var ids = pendingRemoteDeletes[scope.accountID] ?? []
        var unresolved = 0 // corrupt-journal records are reported by ensureNoPendingWork, not counted as transient failures
        for note in localNotes {
            if note.recoveryPaused || note.recoveryPendingDeleteID != nil { continue }
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
            note.remoteId == nil && note.pendingCreateOperationID == nil && note.pendingCleanupRemoteIDs.isEmpty && !note.hasRecoveryHistory {
            modelContext.delete(note)
        }
        try modelContext.save()
        // Per-record errors are retained, but MUST NOT starve unrelated safe uploads.
        return failures + unresolved
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

        if httpResponse.statusCode == 401 && retryAuthOnFailure {
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

    // MARK: - Explicit, account-verified recovery (never invoked by timers or normal sync)

    func recoveryRecords(from notes: [StickyNote]) -> [StickyNote] {
        guard authManager.isAuthenticated, let account = authManager.accountID else { return [] }
        return notes.filter { $0.ownerAccountID == account && $0.hasRecoveryHistory }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
    private func checkRecovery(_ note: StickyNote, scope: Scope) throws {
        guard !note.isDeleted else { throw syncError(-43, "本地记录已变化，请重新选择。") }
        try requireOwner(note, scope: scope)
        guard note.hasRecoveryHistory else { throw syncError(-43, "此记录没有待核对/恢复历史。") }
        guard !note.hasCorruptRecoveryJournal, !note.hasCorruptSyncJournal else {
            throw syncError(-41, "恢复日志损坏，保留原件并停止自动处理；请先导出内容。")
        }
    }
    /// Fresh /me verification, not just a cached display name or email comparison.
    private func freshRecoveryToken(_ note: StickyNote, scope: Scope) async throws -> String {
        try checkRecovery(note, scope: scope)
        let token = try await authManager.getValidAccessToken()
        try validate(scope)
        var request = URLRequest(url: URL(string: "\(graphEndpoint)/me?$select=id")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await scopedData(for: request, scope: scope)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["id"] as? String == scope.accountID else {
            throw syncError(-44, "令牌的微软账号与原记录不一致，未读取候选或执行恢复。")
        }
        try checkRecovery(note, scope: scope)
        return token
    }
    private func readRecoveryCandidate(_ note: StickyNote, id: String, kind: RecoveryRemoteKind,
                                       scope: Scope, token: String, allowPreviouslyVerifiedMissing: Bool = false) async throws -> VerifiedRecoveryCandidate {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = graphItemURL(collection: kind.collection, id: trimmed) else { throw syncError(-45, "请输入完整远端对象 ID。") }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if kind == .mailNote {
            components.queryItems = [URLQueryItem(name: "$expand", value: "singleValueExtendedProperties($filter=id eq 'String 0x001A' or id eq '\(NoteConverter.webNoteJSONPropertyId)')")]
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await scopedData(for: request, scope: scope)
        try checkRecovery(note, scope: scope)
        let status = (response as? HTTPURLResponse)?.statusCode
        let durableDelete = note.recoveryPendingDeleteID == trimmed && note.recoveryPendingDeleteKindRaw == kind.rawValue
        if status == 404, durableDelete || allowPreviouslyVerifiedMissing {
            return VerifiedRecoveryCandidate(sourceID: note.id, accountID: scope.accountID, generation: scope.generation,
                recoveryVersion: note.recoveryVersion, operationID: note.pendingCreateOperationID, wasDeleted: note.isDeletedLocally,
                id: trimmed, kind: kind, exists: false, changeKey: nil, html: "", webNoteJSON: nil)
        }
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["id"] as? String == trimmed, let key = json["changeKey"] as? String, !key.isEmpty,
              let html = (json["body"] as? [String: Any])?["content"] as? String else {
            throw syncError(-45, "候选未通过精确 ID 读取核验。未找到不等于未创建，不会自动解除标记。")
        }
        let properties = json["singleValueExtendedProperties"] as? [[String: Any]] ?? []
        if kind == .mailNote {
            guard properties.contains(where: { ($0["id"] as? String)?.lowercased() == "string 0x001a" &&
                ($0["value"] as? String)?.lowercased() == "ipm.stickynote" }) else {
                throw syncError(-45, "邮箱对象不是已核验的 IPM.StickyNote，禁止关联或删除普通邮件。")
            }
        } else if let type = json["@odata.type"] as? String, type.lowercased() != "#microsoft.graph.note" {
            throw syncError(-45, "候选资源类型不是 Graph note。")
        }
        let webJSON = properties.first { $0["id"] as? String == NoteConverter.webNoteJSONPropertyId }?["value"] as? String
        return VerifiedRecoveryCandidate(sourceID: note.id, accountID: scope.accountID, generation: scope.generation,
            recoveryVersion: note.recoveryVersion, operationID: note.pendingCreateOperationID, wasDeleted: note.isDeletedLocally,
            id: trimmed, kind: kind, exists: true, changeKey: key, html: html, webNoteJSON: webJSON)
    }
    func verifyRecoveryCandidate(_ note: StickyNote, id: String, kind: RecoveryRemoteKind) async throws -> VerifiedRecoveryCandidate {
        let scope = try currentScope()
        try checkRecovery(note, scope: scope)
        let version = note.recoveryVersion, operation = note.pendingCreateOperationID, deleted = note.isDeletedLocally
        let token = try await freshRecoveryToken(note, scope: scope)
        let result = try await readRecoveryCandidate(note, id: id, kind: kind, scope: scope, token: token)
        guard note.recoveryVersion == version, note.pendingCreateOperationID == operation, note.isDeletedLocally == deleted else {
            throw syncError(-43, "本地恢复状态已变化，请重新核对。")
        }
        return result
    }
    private func requireRecoveryConfirmation(_ reason: String, acknowledged: Bool) throws -> String {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acknowledged, !text.isEmpty, text.count <= 1000 else {
            throw syncError(-46, "必须明确确认风险，并填写不含密码/令牌的核对依据（1–1000字）。")
        }
        return text
    }
    private func validateCandidate(_ candidate: VerifiedRecoveryCandidate, note: StickyNote, scope: Scope) throws {
        try checkRecovery(note, scope: scope)
        guard candidate.sourceID == note.id, candidate.accountID == scope.accountID, candidate.generation == scope.generation,
              candidate.recoveryVersion == note.recoveryVersion, candidate.operationID == note.pendingCreateOperationID,
              candidate.wasDeleted == note.isDeletedLocally else { throw syncError(-43, "候选或本地记录已过期/切号，请重新核对。") }
    }
    private func addAudit(_ note: StickyNote, action: String, reason: String, scope: Scope,
                          candidate: VerifiedRecoveryCandidate? = nil, related: [UUID] = []) {
        note.recoveryAudit.append(RecoveryAuditEntry(accountID: scope.accountID, action: action, reason: reason,
            priorOperationID: note.pendingCreateOperationID, remoteID: candidate?.id, kind: candidate?.kind,
            changeKey: candidate?.changeKey, priorEndpoint: note.pendingCreateEndpoint, priorStartedAt: note.pendingCreateStartedAt,
            relatedLocalIDs: related))
        note.recoveryVersion += 1
    }
    private func archiveRecoverySnapshot(_ source: StickyNote, scope: Scope, context: ModelContext) -> StickyNote {
        let copy = StickyNote(color: source.noteColor, content: source.plainTextContent, ownerAccountID: scope.accountID, syncStatus: .synced)
        copy.attributedContentData = source.attributedContentData
        copy.audioRecordings = source.audioRecordings
        copy.webNoteJSON = source.webNoteJSON
        copy.createdAt = source.createdAt; copy.modifiedAt = source.modifiedAt
        copy.windowX = source.windowX; copy.windowY = source.windowY
        copy.windowWidth = source.windowWidth; copy.windowHeight = source.windowHeight
        copy.recoveryPaused = true; copy.recoveryIsArchive = true
        copy.recoveryAudit = [RecoveryAuditEntry(accountID: scope.accountID, action: "local-content-snapshot",
            reason: "用户确认恢复操作前的本地内容与旧元数据保全；未关联远端，不会自动上传。",
            priorOperationID: source.pendingCreateOperationID, remoteID: source.remoteId, kind: nil, changeKey: source.changeKey, priorEndpoint: source.pendingCreateEndpoint, priorStartedAt: source.pendingCreateStartedAt,
            relatedLocalIDs: [source.id])]
        context.insert(copy)
        return copy
    }
    /// S3-C: the candidate's full cloud body is saved locally BEFORE a later PATCH can overwrite it.
    private func archiveCandidateCloudContent(_ candidate: VerifiedRecoveryCandidate, scope: Scope, context: ModelContext, boundTo sourceID: UUID) -> StickyNote {
        let props: [[String: Any]] = candidate.webNoteJSON.map { [["id": NoteConverter.webNoteJSONPropertyId, "value": $0]] } ?? []
        let extracted = NoteConverter.extractNoteColor(fromExtendedProperties: props)
        let copy = StickyNote(color: extracted.color, content: NoteConverter.extractPlainText(from: candidate.html),
                              ownerAccountID: scope.accountID, syncStatus: .synced)
        let attributed = NoteConverter.htmlToAttributedString(candidate.html)
        copy.attributedContentData = try? NSKeyedArchiver.archivedData(withRootObject: attributed, requiringSecureCoding: true)
        copy.webNoteJSON = candidate.webNoteJSON
        copy.recoveryPaused = true; copy.recoveryIsArchive = true
        var entry = RecoveryAuditEntry(accountID: scope.accountID, action: "cloud-content-snapshot-before-association",
            reason: "关联前保存候选云端对象的完整正文，之后的本地上传可能覆盖云端；此副本仅本地保留，不会自动上传。",
            priorOperationID: nil, remoteID: candidate.id, kind: candidate.kind, changeKey: candidate.changeKey,
            relatedLocalIDs: [sourceID])
        entry.candidateHTML = candidate.html
        copy.recoveryAudit = [entry]
        context.insert(copy)
        return copy
    }
    private func retainOldReferences(_ note: StickyNote, except id: String? = nil) {
        var retained = Set(note.recoveryRetainedRemoteIDs + note.pendingCleanupRemoteIDs)
        if let old = note.remoteId, old != id { retained.insert(old) }
        if let id { retained.remove(id) }
        note.recoveryRetainedRemoteIDs = retained.sorted()
        note.pendingCleanupRemoteIDs = [] // recovery never silently schedules deletion of old objects
    }
    private func clearCreateIntent(_ note: StickyNote) {
        note.pendingCreateOperationID = nil; note.pendingCreateEndpoint = nil; note.pendingCreateStartedAt = nil
    }

    func exportRecoveryContent(_ note: StickyNote) throws -> Data {
        let scope = try currentScope()
        guard !note.isDeleted else { throw syncError(-43, "本地记录已移除。") }
        try requireOwner(note, scope: scope)
        // Export is read-only and allowed even if a journal cannot be parsed; raw journal bytes
        // are added separately so corruption is not silently lost.
        let json = try LocalExporter.noteObject(note)
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    func restoreRecoveryLocalOnly(_ note: StickyNote, reason: String, acknowledged: Bool) async throws {
        let scope = try currentScope(), id = note.id
        let text = try requireRecoveryConfirmation(reason, acknowledged: acknowledged)
        await acquireUpload(id); defer { releaseUpload(id) }
        try checkRecovery(note, scope: scope)
        note.recoveryPaused = true; note.isDeletedLocally = false; note.syncStatus = .synced
        addAudit(note, action: "restore-local-only-keep-uncertainty", reason: text, scope: scope)
        try saveDurably(note) // unknown POST marker intentionally remains
    }

    func confirmRecoveryCandidate(_ note: StickyNote, candidate: VerifiedRecoveryCandidate, action: RecoveryAction,
                                  reason: String, acknowledged: Bool) async throws {
        guard [.associate, .deleteCandidate, .deleteRetained].contains(action) else { throw syncError(-46, "无效恢复操作。") }
        let scope = try currentScope(), id = note.id
        let text = try requireRecoveryConfirmation(reason, acknowledged: acknowledged)
        await acquireUpload(id); defer { releaseUpload(id) }
        try validateCandidate(candidate, note: note, scope: scope)
        if action != .deleteRetained, note.pendingCreateOperationID != nil,
            (note.remoteId == candidate.id || note.recoveryRetainedRemoteIDs.contains(candidate.id)) {
            throw syncError(-46, "这是此前已知旧对象，不能用它认领未知的新建结果；可单独核对并删除旧引用。")
        }
        if action == .deleteRetained, !note.recoveryRetainedRemoteIDs.contains(candidate.id) { throw syncError(-46, "该 ID 不在保留的旧对象清单。") }
        if let pending = note.recoveryPendingDeleteID,
            pending != candidate.id || note.recoveryPendingDeleteKindRaw != candidate.kind.rawValue {
            throw syncError(-46, "先核对已有的待确认删除 ID，不能覆盖其日志。")
        }
        if action == .associate, note.recoveryPendingDeleteID != nil { throw syncError(-46, "先完成已有删除核对，再关联。") }
        let token = try await freshRecoveryToken(note, scope: scope)
        let fresh = try await readRecoveryCandidate(note, id: candidate.id, kind: candidate.kind, scope: scope, token: token,
                                                   allowPreviouslyVerifiedMissing: candidate.exists && action != .associate)
        try validateCandidate(candidate, note: note, scope: scope)
        guard fresh.exists == candidate.exists || (!fresh.exists && action != .associate),
              !fresh.exists || fresh.changeKey == candidate.changeKey else { throw syncError(-43, "远端对象版本已变化，请重新预览后确认。") }
        guard let context = note.modelContext else { throw syncError(-33, "本地记录未持久化。") }
        if action == .associate {
            guard fresh.exists, let changeKey = fresh.changeKey else { throw syncError(-45, "不能关联不存在的候选。") }
            let duplicates = try context.fetch(FetchDescriptor<StickyNote>()).filter {
                $0.id != note.id && $0.ownerAccountID == scope.accountID && $0.remoteId == fresh.id
            }
            guard !duplicates.contains(where: { uploadingNoteIDs.contains($0.id) || $0.pendingCreateOperationID != nil || !$0.pendingCleanupRemoteIDs.isEmpty ||
                $0.recoveryPendingDeleteID != nil || $0.hasCorruptRecoveryJournal || $0.hasCorruptSyncJournal || $0.isDeletedLocally }) else {
                throw syncError(-46, "已有本地关联副本含未决操作，需先单独核对；不会静默删除或合并。")
            }
            let archive = archiveRecoverySnapshot(note, scope: scope, context: context)
            let cloudArchive = archiveCandidateCloudContent(fresh, scope: scope, context: context, boundTo: note.id)
            for duplicate in duplicates {
                addAudit(duplicate, action: "archive-local-representation", reason: text, scope: scope, candidate: fresh, related: [note.id])
                duplicate.remoteId = nil; duplicate.changeKey = nil; duplicate.lastSyncedAt = nil
                duplicate.recoveryPaused = true; duplicate.recoveryIsArchive = true; duplicate.syncStatus = .synced
            }
            addAudit(note, action: "associate-user-attested-exact-object", reason: text, scope: scope, candidate: fresh,
                     related: [archive.id, cloudArchive.id] + duplicates.map(\.id))
            retainOldReferences(note, except: fresh.id)
            clearCreateIntent(note)
            note.remoteId = fresh.id; note.changeKey = changeKey
            if let web = fresh.webNoteJSON { note.webNoteJSON = web }
            note.recoveryPaused = false; note.recoveryBlocksAutomaticRecreate = true
            note.isDeletedLocally = false; note.syncStatus = .pendingUpload
            try context.save()
            return // no remote writes; a later regular PATCH may run, but automatic recreate is blocked
        }
        let archive = archiveRecoverySnapshot(note, scope: scope, context: context)
        addAudit(note, action: action == .deleteRetained ? "delete-retained-authorized" : "delete-candidate-authorized",
                 reason: text, scope: scope, candidate: fresh, related: [archive.id])
        if action == .deleteCandidate { note.recoveryPaused = true }
        note.recoveryPendingDeleteID = fresh.id; note.recoveryPendingDeleteKindRaw = fresh.kind.rawValue
        let actionVersion = note.recoveryVersion
        try context.save() // explicit authorization/intention survives lost DELETE response
        if fresh.exists {
            var request = URLRequest(url: graphItemURL(collection: fresh.kind.collection, id: fresh.id)!)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await scopedData(for: request, scope: scope)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) || status == 404 else {
                throw syncError(-47, "删除结果未确认：保留精确 ID 和授权记录，不会自动重发；请重新核对。")
            }
        }
        try checkRecovery(note, scope: scope)
        guard note.recoveryVersion == actionVersion, note.isDeletedLocally == candidate.wasDeleted else {
            throw syncError(-43, "删除后本地状态已变化，保留核对记录，请重新检查。")
        }
        addAudit(note, action: "delete-confirmed-or-previously-authorized-object-absent", reason: text, scope: scope, candidate: fresh)
        if action == .deleteCandidate {
            retainOldReferences(note, except: fresh.id)
            clearCreateIntent(note)
            note.remoteId = nil; note.changeKey = nil; note.lastSyncedAt = nil
            note.isDeletedLocally = false; note.syncStatus = .synced // intentionally local-only, not a cloud success claim
        } else { note.recoveryRetainedRemoteIDs.removeAll { $0 == fresh.id } }
        note.recoveryPendingDeleteID = nil; note.recoveryPendingDeleteKindRaw = nil
        try context.save()
    }

    func retryRecoveryCreate(_ note: StickyNote, expectedVersion: Int, reason: String, acknowledged: Bool) async throws {
        let scope = try currentScope(), id = note.id
        let text = try requireRecoveryConfirmation(reason, acknowledged: acknowledged)
        await acquireUpload(id); defer { releaseUpload(id) }
        try checkRecovery(note, scope: scope)
        guard note.recoveryVersion == expectedVersion else { throw syncError(-43, "恢复请求已过期，请重新确认。") }
        guard note.pendingCreateOperationID != nil || note.recoveryPaused ||
            (note.recoveryBlocksAutomaticRecreate && note.syncStatus != .synced) else { throw syncError(-46, "此对象无需重建，已拒绝重复创建。") }
        guard note.recoveryPendingDeleteID == nil else { throw syncError(-46, "先完成已授权删除的核对，不能直接另建。") }
        let operation = note.pendingCreateOperationID, deleted = note.isDeletedLocally
        let token = try await freshRecoveryToken(note, scope: scope)
        guard note.recoveryVersion == expectedVersion, note.pendingCreateOperationID == operation,
              note.isDeletedLocally == deleted else { throw syncError(-43, "本地状态变化，请重新确认。") }
        guard let context = note.modelContext else { throw syncError(-33, "本地记录未持久化。") }
        let archive = archiveRecoverySnapshot(note, scope: scope, context: context)
        addAudit(note, action: "retry-create-authorized-duplicate-risk-accepted", reason: text, scope: scope, related: [archive.id])
        retainOldReferences(note)
        clearCreateIntent(note)
        note.remoteId = nil; note.changeKey = nil; note.lastSyncedAt = nil
        note.isDeletedLocally = false; note.recoveryPaused = false; note.recoveryBlocksAutomaticRecreate = true
        note.syncStatus = .pendingUpload
        try context.save()
        // No await between clearing the old intent and starting the new durable POST intent;
        // the per-note lock remains held throughout. This is not a "clear flag and hope" action.
        do { try await uploadLocked(note, token: token, retryAuthOnFailure: false, scope: scope) }
        catch {
            if !note.isDeleted { note.syncStatus = .error; try saveDurably(note) }
            throw error
        }
        // The explicit create just produced a definite, journaled object id; the uncertainty that justified the
        // guard is gone, so later edits must not be stuck on -42 for sessions without ShortNotes (S3-A).
        if !note.isDeleted, note.pendingCreateOperationID == nil, note.remoteId != nil, note.recoveryBlocksAutomaticRecreate {
            note.recoveryBlocksAutomaticRecreate = false
            addAudit(note, action: "clear-recreate-guard-after-confirmed-create", reason: "显式重建已拿到确定的云端对象 ID，解除禁止自动重建标记。", scope: scope)
            try saveDurably(note)
        }
    }

    /// S3-A degradation path: when PATCH on a recovered binding keeps failing (e.g. no ShortNotes), the user may
    /// explicitly allow the normal create-then-delete replacement for this one note. Local-only, audited.
    func allowReplacementSync(_ note: StickyNote, reason: String, acknowledged: Bool) throws {
        let scope = try currentScope()
        let text = try requireRecoveryConfirmation(reason, acknowledged: acknowledged)
        try requireOwner(note, scope: scope)
        guard note.recoveryBlocksAutomaticRecreate else { throw syncError(-46, "此便笺没有「禁止自动重建」标记。") }
        guard note.pendingCreateOperationID == nil, note.recoveryPendingDeleteID == nil,
              !note.hasCorruptRecoveryJournal, !note.hasCorruptSyncJournal else {
            throw syncError(-46, "存在未决的创建/删除核对，不能解除标记。")
        }
        addAudit(note, action: "allow-replacement-sync-user-confirmed", reason: text, scope: scope)
        note.recoveryBlocksAutomaticRecreate = false
        if note.syncStatus == .error { note.syncStatus = .pendingUpload }
        try saveDurably(note)
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

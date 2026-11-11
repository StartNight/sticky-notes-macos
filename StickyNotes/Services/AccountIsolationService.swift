import Foundation
import SwiftData

enum IsolationError: LocalizedError {
    case notVerified, stalePrompt, notEligible(String), needsAcknowledgement

    var errorDescription: String? {
        switch self {
        case .notVerified: return "账号身份未确认，已暂停。"
        case .stalePrompt: return "账号或登录状态已变化，请重新确认。"
        case .notEligible(let why): return why
        case .needsAcknowledgement: return "导出其他账号或隔离区的本地数据需要您明确确认。"
        }
    }
}

/// Per-account memory of which no-account notes were already offered (accepted OR declined).
/// Stores only note UUIDs and a decision word, never content, tokens or credentials.
struct AdoptionLedger {
    enum Decision: String { case accepted, declined }
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ accountID: String) -> String { "account_adoption_ledger.v1." + accountID }
    func decisions(for accountID: String) -> [UUID: Decision] {
        guard let raw = defaults.dictionary(forKey: key(accountID)) as? [String: String] else { return [:] }
        var result: [UUID: Decision] = [:]
        for (id, value) in raw { if let uuid = UUID(uuidString: id), let d = Decision(rawValue: value) { result[uuid] = d } }
        return result
    }
    func record(_ ids: [UUID], _ decision: Decision, for accountID: String) {
        var raw = (defaults.dictionary(forKey: key(accountID)) as? [String: String]) ?? [:]
        for id in ids { raw[id.uuidString] = decision.rawValue }
        defaults.set(raw, forKey: key(accountID))
    }
}

/// First-sign-in adoption of no-account notes, legacy quarantine claims, and local-only exports.
/// Nothing here talks to Graph. Upload happens later through the normal, owner-checked sync path.
@MainActor
final class AccountIsolationService {
    static let shared = AccountIsolationService()

    struct AdoptionPrompt: Equatable {
        let accountID: String
        let generation: UUID
        let noteIDs: [UUID]
    }
    enum ClaimTarget { case currentAccount, noAccountLocal }

    private let auth: any SyncAuthProviding
    let ledger: AdoptionLedger
    init(auth: any SyncAuthProviding = AuthManager.shared, ledger: AdoptionLedger = AdoptionLedger()) {
        self.auth = auth
        self.ledger = ledger
    }

    // MARK: First sign-in / re-ask rule

    /// Prompt only for verified accounts, only for no-account notes this account has never been asked
    /// about. Legacy/quarantined data is NEVER offered here.
    /// The scope's account id, but only once `/me.id` has confirmed it (a cached id is provisional at startup).
    private func verifiedAccountID() throws -> String {
        guard case .account(let id) = auth.activeScope, auth.isIdentityVerified else { throw IsolationError.notVerified }
        return id
    }

    func pendingPrompt(modelContext: ModelContext) throws -> AdoptionPrompt? {
        guard case .account(let id) = auth.activeScope, auth.isIdentityVerified else { return nil }
        let notes = try modelContext.fetch(FetchDescriptor<StickyNote>())
        let known = ledger.decisions(for: id)
        let candidates = NoteScopeQuery.unlinked(notes).filter { known[$0.id] == nil }
        guard !candidates.isEmpty else { return nil }
        return AdoptionPrompt(accountID: id, generation: auth.sessionGeneration, noteIDs: candidates.map(\.id))
    }

    private func requireCurrent(_ prompt: AdoptionPrompt) throws {
        guard auth.activeScope == .account(prompt.accountID), auth.isIdentityVerified, auth.sessionGeneration == prompt.generation else {
            throw IsolationError.stalePrompt
        }
    }

    /// Only the notes listed in the dialog are stamped, and only after the user confirmed.
    @discardableResult
    func accept(_ prompt: AdoptionPrompt, modelContext: ModelContext) throws -> Int {
        try requireCurrent(prompt)
        let count = try adopt(ids: prompt.noteIDs, accountID: prompt.accountID, modelContext: modelContext)
        ledger.record(prompt.noteIDs, .accepted, for: prompt.accountID)
        return count
    }

    /// Declining changes nothing in the store: notes stay no-account data.
    func decline(_ prompt: AdoptionPrompt) throws {
        try requireCurrent(prompt)
        ledger.record(prompt.noteIDs, .declined, for: prompt.accountID)
    }

    /// Settings entry (always available while signed in & verified).
    @discardableResult
    func adoptUnlinked(ids: [UUID]? = nil, modelContext: ModelContext) throws -> Int {
        let id = try verifiedAccountID()
        let all = NoteScopeQuery.unlinked(try modelContext.fetch(FetchDescriptor<StickyNote>())).map(\.id)
        let chosen = ids.map { wanted in all.filter { wanted.contains($0) } } ?? all
        let count = try adopt(ids: chosen, accountID: id, modelContext: modelContext)
        ledger.record(chosen, .accepted, for: id)
        return count
    }

    private func adopt(ids: [UUID], accountID: String, modelContext: ModelContext) throws -> Int {
        let wanted = Set(ids)
        var count = 0
        for note in try modelContext.fetch(FetchDescriptor<StickyNote>()) where wanted.contains(note.id) {
            guard note.ownership == .unlinkedLocal, !note.isDeletedLocally else { continue }
            note.ownerAccountID = accountID
            note.syncStatus = .pendingUpload
            count += 1
        }
        try modelContext.save()
        return count
    }

    // MARK: Legacy (unknown ownership) quarantine

    /// Move a never-synced legacy note, one at a time and only on explicit request.
    func claimLegacy(_ note: StickyNote, to target: ClaimTarget, modelContext: ModelContext) throws {
        guard note.ownership == .legacyUnknown, !note.isDeleted else { throw IsolationError.notEligible("该便笺不在隔离区。") }
        guard !note.hasCloudTrace, !note.isDeletedLocally else {
            throw IsolationError.notEligible("该便笺带有云端痕迹，归属可能是任一账号，不能直接认领；请导出或另存为当前账号的新副本。")
        }
        switch target {
        case .currentAccount:
            let id = try verifiedAccountID()
            note.ownerAccountID = id
            note.syncStatus = .pendingUpload
        case .noAccountLocal:
            note.ownerAccountID = StickyNote.unlinkedOwnerMarker
        }
        try modelContext.save()
    }

    /// For legacy notes with cloud traces: explicit copy into the current account. The original stays
    /// quarantined and untouched; the copy carries no cloud ids, so it uploads as a NEW note.
    @discardableResult
    func copyLegacyToCurrentAccount(_ note: StickyNote, modelContext: ModelContext) throws -> StickyNote {
        guard note.ownership == .legacyUnknown, !note.isDeleted else { throw IsolationError.notEligible("该便笺不在隔离区。") }
        let id = try verifiedAccountID()
        let copy = StickyNote(color: note.noteColor, content: note.plainTextContent, ownerAccountID: id, syncStatus: .pendingUpload)
        copy.attributedContentData = note.attributedContentData
        copy.audioRecordings = note.audioRecordings
        copy.createdAt = note.createdAt
        copy.modifiedAt = note.modifiedAt
        modelContext.insert(copy)
        try modelContext.save()
        return copy
    }
}

// MARK: - Local-only export (no Graph, no sign-in needed)

enum LocalExporter {
    /// Full local content + metadata of a single note, without tokens. Same shape as the recovery export.
    static func noteObject(_ note: StickyNote) throws -> [String: Any] {
        let content = RecoveryContentExport(formatVersion: 1, localID: note.id, ownerAccountID: note.ownerAccountID,
            plainText: note.plainTextContent, attributedContentData: note.attributedContentData, audioRecordings: note.audioRecordings,
            color: note.colorRawValue, createdAt: note.createdAt, modifiedAt: note.modifiedAt,
            windowFrame: [note.windowX, note.windowY, note.windowWidth, note.windowHeight], remoteID: note.remoteId,
            changeKey: note.changeKey, webNoteJSON: note.webNoteJSON, isDeletedLocally: note.isDeletedLocally,
            operationID: note.pendingCreateOperationID, operationEndpoint: note.pendingCreateEndpoint,
            operationStartedAt: note.pendingCreateStartedAt, retainedRemoteIDs: note.recoveryRetainedRemoteIDs,
            automaticCleanupRemoteIDs: note.pendingCleanupRemoteIDs, pendingRecoveryDeleteID: note.recoveryPendingDeleteID,
            pendingRecoveryDeleteKind: note.recoveryPendingDeleteKindRaw, recoveryPaused: note.recoveryPaused, audit: note.recoveryAudit)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: encoder.encode(content)) as! [String: Any]
        json["rawRecoveryAuditBase64"] = note.recoveryAuditData?.base64EncodedString()
        json["rawRecoveryRetainedIDsBase64"] = note.recoveryRetainedIDsData?.base64EncodedString()
        json["rawCleanupIDsBase64"] = note.pendingCleanupIDsData?.base64EncodedString()
        return json
    }

    /// Rules: notes visible in the active scope (including its hidden tombstones/recovery records) export
    /// freely. Anything else (other accounts, quarantine, no-account data while signed in, or any note while
    /// identity is unconfirmed) requires `acknowledgedOutOfScope`. Works signed out / offline; never writes.
    static func export(_ notes: [StickyNote], scope: ActiveScope, acknowledgedOutOfScope: Bool) throws -> Data {
        let live = notes.filter { !$0.isDeleted }
        let outOfScope = live.contains { !$0.isVisible(in: scope) }
        if outOfScope && !acknowledgedOutOfScope { throw IsolationError.needsAcknowledgement }
        let object: [String: Any] = [
            "formatVersion": 2,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "includesOutOfScopeData": outOfScope,
            "noteCount": live.count,
            "notes": try live.map(noteObject)
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: - Copy-only safety net before first launch of an isolation build

enum StoreSafetyBackup {
    static let suffix = ".pre-account-isolation"

    /// Copies the store (+ -wal/-shm) once, next to the original. Never overwrites, moves or deletes anything.
    @discardableResult
    static func createIfNeeded(storeURL: URL, fileManager: FileManager = .default) throws -> [URL] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }
        let mainBackup = URL(fileURLWithPath: storeURL.path + suffix)
        guard !fileManager.fileExists(atPath: mainBackup.path) else { return [] }
        var created: [URL] = []
        for extra in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + extra)
            let target = URL(fileURLWithPath: storeURL.path + extra + suffix)
            guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.copyItem(at: source, to: target)
            created.append(target)
        }
        return created
    }
}

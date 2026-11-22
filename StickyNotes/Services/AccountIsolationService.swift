import Foundation
import SwiftData

enum IsolationError: LocalizedError {
    case notVerified, stalePrompt, notEligible(String), needsAcknowledgement
    /// Soft block: a copy is allowed but only after the user confirms (see `allowSimilarContent`).
    case duplicateRisk(String)

    var errorDescription: String? {
        switch self {
        case .notVerified: return "账号身份未确认，已暂停。"
        case .stalePrompt: return "账号或登录状态已变化，请重新确认。"
        case .notEligible(let why): return why
        case .duplicateRisk(let why): return why
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

/// Which legacy (quarantined, cloud-traced) note was already copied into which account. Per account, so the same
/// source may still be copied into a different account. Stores only UUIDs, never content or credentials.
struct LegacyCopyLedger {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ accountID: String) -> String { "legacy_copy_ledger.v1." + accountID }
    func copyID(of source: UUID, for accountID: String) -> UUID? {
        guard let raw = defaults.dictionary(forKey: key(accountID)) as? [String: String] else { return nil }
        return raw[source.uuidString].flatMap(UUID.init(uuidString:))
    }
    func record(source: UUID, copy: UUID, for accountID: String) {
        var raw = (defaults.dictionary(forKey: key(accountID)) as? [String: String]) ?? [:]
        raw[source.uuidString] = copy.uuidString
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
    let copyLedger: LegacyCopyLedger
    init(auth: any SyncAuthProviding = AuthManager.shared, ledger: AdoptionLedger = AdoptionLedger()) {
        self.auth = auth
        self.ledger = ledger
        self.copyLedger = LegacyCopyLedger(defaults: ledger.defaults)
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

    /// EXPLICIT decline ("Keep as No-Account Notes"): changes nothing in the store, and remembers not to ask again
    /// about these notes for this account. Esc / closing the dialog / "Not Now" must NOT come here — see `skip`.
    func decline(_ prompt: AdoptionPrompt) throws {
        try requireCurrent(prompt)
        ledger.record(prompt.noteIDs, .declined, for: prompt.accountID)
    }

    /// "Not Now", Esc, or closing the dialog: skip for this time only. Records nothing and changes nothing, so the
    /// same notes are offered again the next time this account signs in / the app starts.
    func skip(_ prompt: AdoptionPrompt) {
        // Deliberately empty: a dismissal is not a decision.
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
    ///
    /// Duplicate guards (a cloud-traced note's cloud object may already be in this account, because sync pulls every
    /// cloud note down as an owned note):
    ///  1. hard: this source was already copied into this account (and the copy still exists) -> refuse;
    ///  2. hard: the account already holds a note bound to the same cloud object id -> refuse;
    ///  3. soft: the account already holds a note with identical text -> `duplicateRisk`, allowed only with
    ///     `allowSimilarContent: true` (the UI asks the user). Trade-off: text equality can be a coincidence or an
    ///     edited copy, so it asks instead of silently refusing; cloud-side dedupe is impossible without writing.
    @discardableResult
    func copyLegacyToCurrentAccount(_ note: StickyNote, allowSimilarContent: Bool = false, modelContext: ModelContext) throws -> StickyNote {
        guard note.ownership == .legacyUnknown, !note.isDeleted else { throw IsolationError.notEligible("该便笺不在隔离区。") }
        let id = try verifiedAccountID()
        let all = try modelContext.fetch(FetchDescriptor<StickyNote>())
        let mine = all.filter { $0.ownerAccountID == id && !$0.isDeleted && !$0.isDeletedLocally }
        if let copyID = copyLedger.copyID(of: note.id, for: id), mine.contains(where: { $0.id == copyID }) {
            throw IsolationError.notEligible("这条遗留便笺已经复制到当前账号，不能重复复制（重复复制会在云端产生重复便笺）。")
        }
        if let remote = note.remoteId, mine.contains(where: { $0.remoteId == remote }) {
            throw IsolationError.notEligible("当前账号下已有绑定同一云端对象的便笺，无需再复制（复制会在云端产生重复）。")
        }
        let normalized = note.plainTextContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowSimilarContent, !normalized.isEmpty,
           mine.contains(where: { $0.plainTextContent.trimmingCharacters(in: .whitespacesAndNewlines) == normalized }) {
            throw IsolationError.duplicateRisk("当前账号下已有内容相同的便笺。若这条遗留便笺就是它的旧版本，再复制会在云端产生重复便笺。确定仍要复制吗？")
        }
        let copy = StickyNote(color: note.noteColor, content: note.plainTextContent, ownerAccountID: id, syncStatus: .pendingUpload)
        copy.attributedContentData = note.attributedContentData
        copy.audioRecordings = note.audioRecordings
        copy.createdAt = note.createdAt
        copy.modifiedAt = note.modifiedAt
        modelContext.insert(copy)
        try modelContext.save()
        copyLedger.record(source: note.id, copy: copy.id, for: id)
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

    /// Copies the store (+ SQLite `-wal`/`-shm` with valid SQLite sibling names + external storage)
    /// once, next to the original. Copies auxiliary files first and rolls back partial copies on error
    /// so a failed backup never locks out retries. Never overwrites, moves, or deletes the live store.
    @discardableResult
    static func createIfNeeded(storeURL: URL, fileManager: FileManager = .default) throws -> [URL] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }
        let mainBackup = URL(fileURLWithPath: storeURL.path + suffix)
        guard !fileManager.fileExists(atPath: mainBackup.path) else { return [] }

        // Build (source, target) pairs with valid SQLite WAL/SHM sibling names:
        //   default.store.pre-account-isolation-wal / -shm
        // Copy auxiliary files BEFORE the main backup sentinel so partial failure cleans up cleanly.
        var pairs: [(source: URL, target: URL)] = []
        for extra in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + extra)
            let target = URL(fileURLWithPath: storeURL.path + suffix + extra)
            if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: target.path) {
                pairs.append((source, target))
            }
        }
        // CoreData/SwiftData external storage directory (e.g. `.default_SUPPORT` for `default.store`)
        let baseName = storeURL.deletingPathExtension().lastPathComponent
        let externalSupport = storeURL.deletingLastPathComponent().appendingPathComponent(".\(baseName)_SUPPORT")
        let externalBackup = storeURL.deletingLastPathComponent().appendingPathComponent(".\(baseName)_SUPPORT\(suffix)")
        if fileManager.fileExists(atPath: externalSupport.path), !fileManager.fileExists(atPath: externalBackup.path) {
            pairs.append((externalSupport, externalBackup))
        }
        pairs.append((storeURL, mainBackup))

        var created: [URL] = []
        do {
            for pair in pairs {
                try fileManager.copyItem(at: pair.source, to: pair.target)
                created.append(pair.target)
            }
        } catch {
            // Roll back partial backup files so the next launch can retry cleanly.
            for url in created.reversed() {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
        return created
    }
}


// MARK: - App-level first-sign-in prompt (not tied to any window)

enum AdoptionChoice: Equatable {
    case accept      // "Sync to This Account"
    case decline     // explicit "Keep as No-Account Notes" -> remembered
    case skip        // "Not Now" / Esc / close -> asked again next time
}

struct AdoptionPromptInfo: Equatable {
    let accountLabel: String
    let count: Int
    let titles: [String]
}

@MainActor
protocol AdoptionPromptPresenting: AnyObject {
    /// Must return `.skip` for Esc/close. Must work with no window on screen.
    func present(_ info: AdoptionPromptInfo) async -> AdoptionChoice
}

/// Owns "when do we ask about no-account notes". It observes the auth state itself instead of living inside the
/// notes-list view, so the question is asked even if the list window was closed or never shown (floating note
/// windows only), and the dialog is an app-level alert, not part of any window's view tree.
@MainActor
final class AdoptionPromptCoordinator {
    static let shared = AdoptionPromptCoordinator()

    private let auth: any SyncAuthProviding
    private let service: AccountIsolationService
    private var presenter: (any AdoptionPromptPresenting)?
    private var context: ModelContext?
    private var afterAccept: (@MainActor (ModelContext) async -> Void)?
    private var accountLabel: () -> String
    private var started = false
    private var evaluating = false
    /// Prompts already answered or skipped in this login session (account + generation): never re-asked in a loop.
    private var handled: Set<String> = []
    private(set) var lastError: String?

    init(auth: any SyncAuthProviding = AuthManager.shared, service: AccountIsolationService = .shared,
         accountLabel: @escaping () -> String = { "this account" }) {
        self.auth = auth
        self.service = service
        self.accountLabel = accountLabel
    }

    func start(context: ModelContext, presenter: any AdoptionPromptPresenting,
               accountLabel: (() -> String)? = nil,
               afterAccept: (@MainActor (ModelContext) async -> Void)? = nil) {
        guard !started else { return }
        started = true
        self.context = context
        self.presenter = presenter
        self.afterAccept = afterAccept
        if let accountLabel { self.accountLabel = accountLabel }
        Task { await self.evaluate(); self.arm() }
    }

    private func arm() {
        withObservationTracking {
            _ = auth.activeScope
            _ = auth.isIdentityVerified
            _ = auth.sessionGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.evaluate()
                self.arm()
            }
        }
    }

    /// Ask about every pending no-account note set, one dialog at a time, until nothing new is pending.
    func evaluate() async {
        guard !evaluating, let context, let presenter else { return }
        evaluating = true
        defer { evaluating = false }
        while let prompt = try? service.pendingPrompt(modelContext: context) {
            let key = "\(prompt.accountID)|\(prompt.generation.uuidString)"
            guard !handled.contains(key) else { return }
            handled.insert(key)
            let notes = (try? context.fetch(FetchDescriptor<StickyNote>())) ?? []
            let titles = notes.filter { prompt.noteIDs.contains($0.id) }.prefix(3).map(\.title)
            let choice = await presenter.present(AdoptionPromptInfo(accountLabel: accountLabel(), count: prompt.noteIDs.count, titles: titles))
            do {
                switch choice {
                case .accept:
                    try service.accept(prompt, modelContext: context)
                    await afterAccept?(context)
                case .decline: try service.decline(prompt)
                case .skip: service.skip(prompt)
                }
            } catch {
                lastError = error.localizedDescription   // stale prompt (signed out/switched while open): nothing changed
            }
        }
    }
}

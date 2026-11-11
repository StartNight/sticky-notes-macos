import Foundation

/// Which slice of the single local store the UI / sync layer may see right now.
///
/// Isolation rule (strict): a note is visible only when its owner matches the active scope.
///  - `.account(id)`   : verified Graph `/me.id`; shows ONLY notes owned by that id.
///  - `.unlinkedLocal` : not signed in; shows ONLY "no-account" notes (explicit local marker).
///  - `.blocked`       : sign-in in progress / identity not yet verified; shows NOTHING.
/// Legacy notes (owner == nil, created by builds before isolation) are never visible in any scope;
/// they live in quarantine until the user explicitly claims them one by one.
enum ActiveScope: Equatable, Hashable {
    case unlinkedLocal
    case account(String)
    case blocked

    static func resolve(isAuthenticated: Bool, isAuthenticating: Bool, accountID: String?) -> ActiveScope {
        if let id = accountID, !id.isEmpty {
            return isAuthenticated && id != StickyNote.unlinkedOwnerMarker ? .account(id) : .blocked
        }
        return (isAuthenticated || isAuthenticating) ? .blocked : .unlinkedLocal
    }

    var accountID: String? {
        if case .account(let id) = self { return id }
        return nil
    }
}

extension StickyNote {
    /// Stored in `ownerAccountID` for notes created while signed out. Not a possible Graph id (GUID),
    /// and never equal to a signed-in account, so every pre-isolation sync path ignores such notes.
    /// No schema change: older builds simply see "an account that is not the current one".
    static let unlinkedOwnerMarker = "local:unlinked"

    enum Ownership: Equatable {
        case legacyUnknown
        case unlinkedLocal
        case account(String)
    }

    var ownership: Ownership {
        guard let owner = ownerAccountID, !owner.isEmpty else { return .legacyUnknown }
        return owner == Self.unlinkedOwnerMarker ? .unlinkedLocal : .account(owner)
    }

    func isVisible(in scope: ActiveScope) -> Bool {
        switch (scope, ownership) {
        case (.unlinkedLocal, .unlinkedLocal): return true
        case (.account(let active), .account(let owner)): return active == owner
        default: return false
        }
    }

    /// Any trace of having talked to a cloud account. Such legacy data may belong to ANY account.
    var hasCloudTrace: Bool {
        remoteId != nil || changeKey != nil || webNoteJSON != nil || lastSyncedAt != nil ||
        pendingCreateOperationID != nil || hasCorruptSyncJournal || !pendingCleanupRemoteIDs.isEmpty || hasRecoveryHistory
    }

    /// Notes are stamped with their owner at creation. Returns nil while identity is not confirmed.
    static func make(in scope: ActiveScope, color: NoteColor = .yellow, content: String = "") -> StickyNote? {
        switch scope {
        case .blocked: return nil
        case .unlinkedLocal:
            return StickyNote(color: color, content: content, ownerAccountID: unlinkedOwnerMarker)
        case .account(let id):
            return StickyNote(color: color, content: content, ownerAccountID: id)
        }
    }
}

/// Single choke point for every list / search / window-restore / recovery query.
enum NoteScopeQuery {
    static func visible(_ notes: [StickyNote], in scope: ActiveScope) -> [StickyNote] {
        StickyNote.visibleNewestFirst(notes.filter { !$0.isDeleted && $0.isVisible(in: scope) })
    }

    static func search(_ notes: [StickyNote], text: String, in scope: ActiveScope) -> [StickyNote] {
        let visible = visible(notes, in: scope)
        guard !text.isEmpty else { return visible }
        let query = text.lowercased()
        return visible.filter { $0.plainTextContent.lowercased().contains(query) }
    }

    /// Pre-isolation notes with unknown ownership (hidden everywhere, never auto-assigned).
    static func quarantined(_ notes: [StickyNote]) -> [StickyNote] {
        notes.filter { !$0.isDeleted && $0.ownership == .legacyUnknown }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// No-account notes, including while a different scope is active (used for prompts/settings only).
    static func unlinked(_ notes: [StickyNote]) -> [StickyNote] {
        notes.filter { !$0.isDeleted && !$0.isDeletedLocally && $0.ownership == .unlinkedLocal }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Counts only; other accounts' content is never listed outside an explicit export.
    static func foreignAccountCounts(_ notes: [StickyNote], in scope: ActiveScope) -> [String: Int] {
        var result: [String: Int] = [:]
        for note in notes where !note.isDeleted {
            if case .account(let owner) = note.ownership, scope.accountID != owner { result[owner, default: 0] += 1 }
        }
        return result
    }

    struct WindowPlan: Equatable {
        var toClose: [UUID]
        var toRestore: [UUID]
    }

    /// On every scope change: close windows of notes outside the scope (keeping their `isOpen` flag),
    /// and reopen windows of in-scope notes that were open when their scope was last active.
    static func windowPlan(notes: [StickyNote], scope: ActiveScope, openWindowIDs: Set<UUID>) -> WindowPlan {
        let byID = Dictionary(notes.filter { !$0.isDeleted }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let close = openWindowIDs.filter { id in
            guard let note = byID[id] else { return true }
            return !note.isVisible(in: scope) || note.isDeletedLocally
        }
        let restore = notes.filter { !$0.isDeleted && $0.isOpen && !$0.isDeletedLocally && $0.isVisible(in: scope) && !openWindowIDs.contains($0.id) }
        return WindowPlan(toClose: close.sorted { $0.uuidString < $1.uuidString },
                          toRestore: restore.map(\.id).sorted { $0.uuidString < $1.uuidString })
    }
}

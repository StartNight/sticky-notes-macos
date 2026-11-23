import Foundation

enum RecoveryRemoteKind: String, Codable, CaseIterable {
    case graphNote, mailNote
    var collection: String { self == .graphNote ? "me/notes" : "me/messages" }
    var label: String { self == .graphNote ? String(localized: "Graph Note") : String(localized: "Mailbox Sticky Note") }
}

enum RecoveryAction: String {
    case associate, deleteCandidate, deleteRetained, retryCreate, restoreLocal
}

struct RecoveryAuditEntry: Codable {
    var date: Date = Date()
    let accountID: String
    let action: String
    let reason: String
    let priorOperationID: String?
    let remoteID: String?
    let kind: RecoveryRemoteKind?
    let changeKey: String?
    var priorEndpoint: String? = nil
    var priorStartedAt: Date? = nil
    var relatedLocalIDs: [UUID] = []
    /// Full cloud body preserved before an association (S3-C). Optional so older journals still decode.
    var candidateHTML: String? = nil

    init(
        date: Date = Date(),
        accountID: String,
        action: String,
        reason: String,
        priorOperationID: String?,
        remoteID: String?,
        kind: RecoveryRemoteKind?,
        changeKey: String?,
        priorEndpoint: String? = nil,
        priorStartedAt: Date? = nil,
        relatedLocalIDs: [UUID] = [],
        candidateHTML: String? = nil
    ) {
        self.date = date
        self.accountID = accountID
        self.action = action
        self.reason = reason
        self.priorOperationID = priorOperationID
        self.remoteID = remoteID
        self.kind = kind
        self.changeKey = changeKey
        self.priorEndpoint = priorEndpoint
        self.priorStartedAt = priorStartedAt
        self.relatedLocalIDs = relatedLocalIDs
        self.candidateHTML = candidateHTML
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date(timeIntervalSince1970: 0)
        accountID = try c.decode(String.self, forKey: .accountID)
        action = try c.decode(String.self, forKey: .action)
        reason = try c.decode(String.self, forKey: .reason)
        priorOperationID = try c.decodeIfPresent(String.self, forKey: .priorOperationID)
        remoteID = try c.decodeIfPresent(String.self, forKey: .remoteID)
        kind = try c.decodeIfPresent(RecoveryRemoteKind.self, forKey: .kind)
        changeKey = try c.decodeIfPresent(String.self, forKey: .changeKey)
        priorEndpoint = try c.decodeIfPresent(String.self, forKey: .priorEndpoint)
        priorStartedAt = try c.decodeIfPresent(Date.self, forKey: .priorStartedAt)
        relatedLocalIDs = try c.decodeIfPresent([UUID].self, forKey: .relatedLocalIDs) ?? []
        candidateHTML = try c.decodeIfPresent(String.self, forKey: .candidateHTML)
    }
}

struct VerifiedRecoveryCandidate {
    let sourceID: UUID
    let accountID: String
    let generation: UUID
    let recoveryVersion: Int
    let operationID: String?
    let wasDeleted: Bool
    let id: String
    let kind: RecoveryRemoteKind
    let exists: Bool
    let changeKey: String?
    let html: String
    let webNoteJSON: String?
}

/// Exported only in response to a user's explicit Save action; never contains credentials.
struct RecoveryContentExport: Codable {
    let formatVersion: Int
    let localID: UUID
    let ownerAccountID: String?
    let plainText: String
    let attributedContentData: Data?
    let audioRecordings: [Data]
    let color: String
    let createdAt: Date
    let modifiedAt: Date
    let windowFrame: [Double]
    let remoteID: String?
    let changeKey: String?
    let webNoteJSON: String?
    let isDeletedLocally: Bool
    let operationID: String?
    let operationEndpoint: String?
    let operationStartedAt: Date?
    let retainedRemoteIDs: [String]
    let automaticCleanupRemoteIDs: [String]
    let pendingRecoveryDeleteID: String?
    let pendingRecoveryDeleteKind: String?
    let recoveryPaused: Bool
    var recoveryBlocksAutomaticRecreate: Bool = false
    var recoveryIsArchive: Bool = false
    var syncStatus: String = SyncStatus.pendingUpload.rawValue
    let audit: [RecoveryAuditEntry]
    var rawRecoveryAuditBase64: String? = nil
    var rawRecoveryRetainedIDsBase64: String? = nil
    var rawCleanupIDsBase64: String? = nil
}

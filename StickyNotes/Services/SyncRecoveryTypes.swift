import Foundation

enum RecoveryRemoteKind: String, Codable, CaseIterable {
    case graphNote, mailNote
    var collection: String { self == .graphNote ? "me/notes" : "me/messages" }
    var label: String { self == .graphNote ? "Graph Note" : "Mailbox Sticky Note" }
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
    let audit: [RecoveryAuditEntry]
}

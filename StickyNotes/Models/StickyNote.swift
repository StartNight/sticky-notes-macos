import AppKit
import SwiftData

enum SyncStatus: String, Codable, CaseIterable {
    case synced
    case pendingUpload
    case error

    var displayName: String {
        switch self {
        case .synced: return String(localized: "Synced")
        case .pendingUpload: return String(localized: "Pending Upload")
        case .error: return String(localized: "Sync Error")
        }
    }
}

@Model
final class StickyNote {
    var id: UUID
    var plainTextContent: String
    var attributedContentData: Data?
    var colorRawValue: String
    var windowX: Double
    var windowY: Double
    var windowWidth: Double
    var windowHeight: Double
    var createdAt: Date
    var modifiedAt: Date
    var isOpen: Bool

    @Attribute(.externalStorage)
    var audioRecordings: [Data]

    // MARK: - Cloud Sync Metadata
    /// Graph /me.id of the owning account. Nil means local-only/quarantined legacy data.
    var ownerAccountID: String?
    var remoteId: String?
    var changeKey: String?
    var syncStatusRaw: String
    var lastSyncedAt: Date?
    /// Tombstone: note was deleted locally and is waiting for a successful remote DELETE.
    var isDeletedLocally: Bool = false
    /// Last known modern `_Note` JSON from Graph, used to merge color without wiping OWA document data.
    var webNoteJSON: String?
    /// Durable write-ahead marker. A lost POST response is NOT permission to POST again.
    var pendingCreateOperationID: String?
    var pendingCreateEndpoint: String?
    var pendingCreateStartedAt: Date?
    /// Durable old-object cleanup journal, account ownership inherited from this note.
    var pendingCleanupIDsData: Data?
    var recoveryPaused: Bool = false
    var recoveryIsArchive: Bool = false
    var recoveryBlocksAutomaticRecreate: Bool = false
    var recoveryVersion: Int = 0
    var recoveryAuditData: Data?
    var recoveryRetainedIDsData: Data?
    var recoveryPendingDeleteID: String?
    var recoveryPendingDeleteKindRaw: String?
    var recoveryAudit: [RecoveryAuditEntry] {
        get { recoveryAuditData.flatMap { try? JSONDecoder().decode([RecoveryAuditEntry].self, from: $0) } ?? [] }
        set {
            // Never overwrite corrupt recovery journal bytes silently.
            guard !hasCorruptRecoveryJournal else { return }
            if newValue.isEmpty {
                recoveryAuditData = nil
            } else if let encoded = try? JSONEncoder().encode(newValue) {
                recoveryAuditData = encoded
            }
        }
    }
    var recoveryRetainedRemoteIDs: [String] {
        get { recoveryRetainedIDsData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set {
            guard !hasCorruptRecoveryJournal else { return }
            if newValue.isEmpty {
                recoveryRetainedIDsData = nil
            } else if let encoded = try? JSONEncoder().encode(newValue) {
                recoveryRetainedIDsData = encoded
            }
        }
    }
    var hasCorruptRecoveryJournal: Bool {
        if let data = recoveryAuditData, (try? JSONDecoder().decode([RecoveryAuditEntry].self, from: data)) == nil { return true }
        if let data = recoveryRetainedIDsData, (try? JSONDecoder().decode([String].self, from: data)) == nil { return true }
        return false
    }
    /// True only while active, unresolved recovery work remains (blocks auto-purge / reports sync problem).
    var hasUnresolvedRecoveryState: Bool {
        pendingCreateOperationID != nil || recoveryPendingDeleteID != nil ||
        !recoveryRetainedRemoteIDs.isEmpty || hasCorruptRecoveryJournal ||
        (recoveryPaused && syncStatus == .error) ||
        (recoveryBlocksAutomaticRecreate && syncStatus != .synced)
    }
    var hasRecoveryHistory: Bool {
        pendingCreateOperationID != nil || recoveryPaused || recoveryPendingDeleteID != nil ||
        recoveryAuditData != nil || recoveryRetainedIDsData != nil || hasCorruptRecoveryJournal ||
        (recoveryBlocksAutomaticRecreate && syncStatus != .synced)
    }
    var pendingCleanupRemoteIDs: [String] {
        get { pendingCleanupIDsData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set {
            // Never overwrite corrupt sync cleanup journal bytes silently.
            guard !hasCorruptSyncJournal else { return }
            if newValue.isEmpty {
                pendingCleanupIDsData = nil
            } else if let encoded = try? JSONEncoder().encode(newValue) {
                pendingCleanupIDsData = encoded
            }
        }
    }
    var hasCorruptSyncJournal: Bool {
        guard let data = pendingCleanupIDsData else { return false }
        return (try? JSONDecoder().decode([String].self, from: data)) == nil
    }
    var requiresRemoteCleanup: Bool {
        remoteId != nil || pendingCreateOperationID != nil || hasCorruptSyncJournal || !pendingCleanupRemoteIDs.isEmpty || hasUnresolvedRecoveryState
    }

    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .pendingUpload }
        set { syncStatusRaw = newValue.rawValue }
    }

    var noteColor: NoteColor {
        get { NoteColor.fromPersisted(colorRawValue) }
        set { colorRawValue = newValue.rawValue }
    }

    @Transient private var cachedRedactedKey: Int?
    @Transient private var cachedRedactedValue: String?

    /// Plain text with hidden ranges replaced by "•••".
    /// Ranges are applied directly to `attrStr.string` (never mismatched against `plainTextContent`)
    /// and memoized across repeated SwiftUI card renders.
    var redactedPlainText: String {
        var hasher = Hasher()
        hasher.combine(plainTextContent)
        hasher.combine(attributedContentData)
        let key = hasher.finalize()
        if cachedRedactedKey == key, let cached = cachedRedactedValue {
            return cached
        }

        let computed: String
        if let data = attributedContentData,
           let attrStr = try? NSKeyedUnarchiver.unarchivedObject(
               ofClasses: [NSAttributedString.self, NSFont.self, NSColor.self,
                           NSParagraphStyle.self, NSShadow.self, NSTextAttachment.self],
               from: data
           ) as? NSAttributedString {
            var result = attrStr.string
            let hiddenKey = NSAttributedString.Key("com.stickynotes.hiddenText")
            var hiddenRanges: [NSRange] = []

            attrStr.enumerateAttribute(hiddenKey, in: NSRange(location: 0, length: attrStr.length)) { value, range, _ in
                if value as? Bool == true {
                    hiddenRanges.append(range)
                }
            }

            if hiddenRanges.isEmpty {
                computed = plainTextContent.isEmpty ? result : plainTextContent
            } else {
                // Apply UTF-16 ranges directly against `attrStr.string` in reverse order so indices always match.
                for range in hiddenRanges.reversed() {
                    guard let swiftRange = Range(range, in: result) else { continue }
                    result.replaceSubrange(swiftRange, with: "•••")
                }
                computed = result.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        } else {
            computed = plainTextContent
        }

        cachedRedactedKey = key
        cachedRedactedValue = computed
        return computed
    }

    var title: String {
        let firstLine = redactedPlainText.components(separatedBy: .newlines).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "New Note") : String(trimmed.prefix(100))
    }

    var preview: String {
        let lines = redactedPlainText.components(separatedBy: .newlines)
        let remaining = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(remaining.prefix(200))
    }

    init(
        color: NoteColor = .yellow,
        content: String = "",
        remoteId: String? = nil,
        ownerAccountID: String? = nil,
        changeKey: String? = nil,
        syncStatus: SyncStatus = .pendingUpload,
        lastSyncedAt: Date? = nil
    ) {
        let screen: NSRect = Thread.isMainThread
            ? (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            : NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: Double = 300
        let height: Double = 350
        let minX = screen.origin.x + 40
        let maxX = max(minX, screen.origin.x + screen.width - width - 40)
        let minY = screen.origin.y + 40
        let maxY = max(minY, screen.origin.y + screen.height - height - 40)
        let randX = Double.random(in: minX...maxX)
        let randY = Double.random(in: minY...maxY)
        let now = Date()

        self.id = UUID()
        self.plainTextContent = content
        self.attributedContentData = nil
        self.colorRawValue = color.rawValue
        self.windowX = randX
        self.windowY = randY
        self.windowWidth = width
        self.windowHeight = height
        self.createdAt = now
        self.modifiedAt = now
        self.isOpen = false
        self.audioRecordings = []

        self.ownerAccountID = ownerAccountID
        self.remoteId = remoteId
        self.changeKey = changeKey
        self.syncStatusRaw = syncStatus.rawValue
        self.lastSyncedAt = lastSyncedAt
        self.isDeletedLocally = false
        self.webNoteJSON = nil
    }

    // MARK: - Mutations

    /// 用户在颜色选择器中的显式选择。将颜色标为「本地已改」，同步才可以向云端写颜色属性；
    /// 其余写入路径都不会改动网页原色（见 `ColorEditLedger`）。
    func setColor(_ color: NoteColor, ledger: ColorEditLedger = .shared) {
        noteColor = color
        ledger.markDirty(id)
        modifiedAt = Date()
        if !recoveryPaused && pendingCreateOperationID == nil && !hasCorruptSyncJournal && !hasCorruptRecoveryJournal {
            syncStatus = .pendingUpload
        }
    }

    func addAudioRecording(_ data: Data) {
        audioRecordings.append(data)
        modifiedAt = Date()
        if !recoveryPaused && pendingCreateOperationID == nil && !hasCorruptSyncJournal && !hasCorruptRecoveryJournal {
            syncStatus = .pendingUpload
        }
    }

    func removeAudioRecording(at index: Int) {
        guard audioRecordings.indices.contains(index) else { return }
        audioRecordings.remove(at: index)
        modifiedAt = Date()
        if !recoveryPaused && pendingCreateOperationID == nil && !hasCorruptSyncJournal && !hasCorruptRecoveryJournal {
            syncStatus = .pendingUpload
        }
    }

    /// List order: newest `modifiedAt` first; tombstones stay hidden.
    static func visibleNewestFirst(_ notes: [StickyNote]) -> [StickyNote] {
        notes
            .filter { !$0.isDeletedLocally }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt {
                    return $0.modifiedAt > $1.modifiedAt
                }
                return $0.createdAt > $1.createdAt
            }
    }

    /// Prefer the later stamp so a stale/default Graph timestamp cannot bury a just-created note.
    static func resolvedModifiedAt(local: Date, remote: Date?) -> Date {
        guard let remote else { return local }
        return max(local, remote)
    }
}


/// 记录两类便笺：用户在本地选过、但尚未送达云端的颜色（dirty）；以及尚未上传、必须原样搬运云端原色、不得推断的副本（carry）。
///
/// 刻意放在 UserDefaults，而不是 SwiftData 字段：库结构与 c34d2e7/f23e122 保持一致
///（旧版本仍可直接打开同一库；无需迁移，也不会因打开失败而 fatalError）。
/// 因此旧数据默认「不脏」。若台账丢失，失败方向是保守的：本地改色不会上传（绝不会用推断色覆盖网页原色）。
final class ColorEditLedger: @unchecked Sendable {
    static let shared = ColorEditLedger()
    static let capacity = 2000
    private static let dirtyKey = "ColorEditLedger.dirty.v1"
    private static let carryKey = "ColorEditLedger.carry.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func read(_ key: String) -> [String] { defaults.stringArray(forKey: key) ?? [] }
    private func write(_ list: [String], _ key: String) {
        defaults.set(Array(list.suffix(Self.capacity)), forKey: key)
    }
    private func add(_ id: UUID, to key: String, removingFrom other: String) {
        lock.lock(); defer { lock.unlock() }
        let value = id.uuidString
        var mine = read(key)
        if !mine.contains(value) { mine.append(value); write(mine, key) }
        var theirs = read(other)
        if theirs.contains(value) { theirs.removeAll { $0 == value }; write(theirs, other) }
    }
    private func remove(_ id: UUID, from key: String) {
        lock.lock(); defer { lock.unlock() }
        var list = read(key)
        if list.contains(id.uuidString) { list.removeAll { $0 == id.uuidString }; write(list, key) }
    }
    private func contains(_ id: UUID, _ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return read(key).contains(id.uuidString)
    }

    func isDirty(_ id: UUID) -> Bool { contains(id, Self.dirtyKey) }
    func isCarry(_ id: UUID) -> Bool { contains(id, Self.carryKey) }
    func markDirty(_ id: UUID) { add(id, to: Self.dirtyKey, removingFrom: Self.carryKey) }
    func markCarry(_ id: UUID) { add(id, to: Self.carryKey, removingFrom: Self.dirtyKey) }
    func clearDirty(_ id: UUID) { remove(id, from: Self.dirtyKey) }
    func clearCarry(_ id: UUID) { remove(id, from: Self.carryKey) }
}

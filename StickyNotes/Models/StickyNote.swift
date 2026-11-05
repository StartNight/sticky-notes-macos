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
    var remoteId: String?
    var changeKey: String?
    var syncStatusRaw: String
    var lastSyncedAt: Date?
    /// Tombstone: note was deleted locally and is waiting for a successful remote DELETE.
    var isDeletedLocally: Bool = false

    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .pendingUpload }
        set { syncStatusRaw = newValue.rawValue }
    }

    var noteColor: NoteColor {
        get { NoteColor(rawValue: colorRawValue) ?? .yellow }
        set { colorRawValue = newValue.rawValue }
    }

    /// Plain text with hidden ranges replaced by "•••"
    private var redactedText: String {
        guard let data = attributedContentData,
              let attrStr = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClasses: [NSAttributedString.self, NSFont.self, NSColor.self,
                              NSParagraphStyle.self, NSShadow.self, NSTextAttachment.self],
                  from: data
              ) as? NSAttributedString else {
            return plainTextContent
        }

        var result = plainTextContent
        let hiddenKey = NSAttributedString.Key("com.stickynotes.hiddenText")
        var hiddenRanges: [NSRange] = []

        attrStr.enumerateAttribute(hiddenKey, in: NSRange(location: 0, length: attrStr.length)) { value, range, _ in
            if value as? Bool == true {
                hiddenRanges.append(range)
            }
        }

        // Replace in reverse order so indices stay valid
        for range in hiddenRanges.reversed() {
            guard let swiftRange = Range(range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: "•••")
        }
        return result
    }

    var title: String {
        let firstLine = redactedText.components(separatedBy: .newlines).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "New Note") : String(trimmed.prefix(100))
    }

    var preview: String {
        let lines = redactedText.components(separatedBy: .newlines)
        let remaining = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(remaining.prefix(200))
    }

    init(
        color: NoteColor = .yellow,
        content: String = "",
        remoteId: String? = nil,
        changeKey: String? = nil,
        syncStatus: SyncStatus = .pendingUpload,
        lastSyncedAt: Date? = nil
    ) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: Double = 300
        let height: Double = 350
        let maxX = max(screen.origin.x, screen.origin.x + screen.width - width - 40)
        let maxY = max(screen.origin.y, screen.origin.y + screen.height - height - 40)
        let randX = Double.random(in: (screen.origin.x + 40)...maxX)
        let randY = Double.random(in: (screen.origin.y + 40)...maxY)

        self.id = UUID()
        self.plainTextContent = content
        self.attributedContentData = nil
        self.colorRawValue = color.rawValue
        self.windowX = randX
        self.windowY = randY
        self.windowWidth = width
        self.windowHeight = height
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.isOpen = false
        self.audioRecordings = []

        self.remoteId = remoteId
        self.changeKey = changeKey
        self.syncStatusRaw = syncStatus.rawValue
        self.lastSyncedAt = lastSyncedAt
        self.isDeletedLocally = false
    }

    // MARK: - Mutations

    func setColor(_ color: NoteColor) {
        noteColor = color
        modifiedAt = Date()
        syncStatus = .pendingUpload
    }

    func addAudioRecording(_ data: Data) {
        audioRecordings.append(data)
        modifiedAt = Date()
        syncStatus = .pendingUpload
    }

    func removeAudioRecording(at index: Int) {
        guard audioRecordings.indices.contains(index) else { return }
        audioRecordings.remove(at: index)
        modifiedAt = Date()
        syncStatus = .pendingUpload
    }
}

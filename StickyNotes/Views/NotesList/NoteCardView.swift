import SwiftUI

struct NoteCardView: View {
    let note: StickyNote
    let isCollapsed: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let previewText = isCollapsed ? "" : note.preview
        let isCharcoalLight = note.noteColor == .charcoal && colorScheme == .light
        let showPendingUpload = note.syncStatus == .pendingUpload &&
            note.ownerAccountID != nil &&
            !SyncEngine.shared.isUntouchedBlankNewNote(note)
        VStack(alignment: .leading, spacing: isCollapsed ? 0 : 6) {
            HStack {
                Text(note.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isCharcoalLight ? Color.white.opacity(0.95) : Color.primary)

                Spacer()

                if note.syncStatus == .error {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .help(String(localized: "Sync error"))
                } else if showPendingUpload {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9))
                        .foregroundStyle(isCharcoalLight ? Color.white.opacity(0.75) : Color.secondary)
                        .help(String(localized: "Pending upload"))
                }

                if !note.audioRecordings.isEmpty {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isCharcoalLight ? Color.white.opacity(0.65) : Color(nsColor: .tertiaryLabelColor))
                        .accessibilityLabel(String(localized: "Has audio recordings"))
                }

                Text(note.modifiedAt.noteListFormatted)
                    .font(.system(size: 10))
                    .foregroundStyle(isCharcoalLight ? Color.white.opacity(0.65) : Color(nsColor: .tertiaryLabelColor))
            }

            if !isCollapsed && !previewText.isEmpty {
                Text(previewText)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .foregroundStyle(isCharcoalLight ? Color.white.opacity(0.78) : Color.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCollapsed ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(note.noteColor.backgroundColor(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(String(localized: "Open Note")) { onOpen() }
            Divider()
            Menu(String(localized: "Color")) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    Button {
                        guard !note.isDeleted, !note.isDeletedLocally else { return }
                        note.setColor(color)
                        if let context = note.modelContext {
                            do {
                                try context.save()
                                SyncEngine.shared.scheduleDebouncedPush(for: note.id, in: context)
                            } catch {
                                SyncEngine.shared.state = .error("无法保存颜色更改：\(error.localizedDescription)")
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: note.noteColor == color ? "checkmark.circle.fill" : "circle.fill")
                            Text(color.displayName)
                        }
                    }
                }
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) { onDelete() }
        }
    }
}

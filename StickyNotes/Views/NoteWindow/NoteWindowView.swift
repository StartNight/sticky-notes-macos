import SwiftUI
import SwiftData

struct NoteWindowView: View {
    let noteID: UUID
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(WindowManager.self) private var windowManager
    @State private var note: StickyNote?
    @State private var attributedText = NSAttributedString()
    @State private var plainText = ""
    @State private var editorProxy = TextEditorProxy()
    @State private var audioRecorder = AudioRecorder()
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var showDeleteConfirmation = false
    @State private var dictationAnchor: Int?
    @State private var dictationLength: Int = 0
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete = true

    /// The note if it is still backed by a live SwiftData model.
    /// Returns nil once the note has been deleted so callers can't read
    /// properties off a tombstoned model (which would crash).
    private var liveNote: StickyNote? {
        guard let note, !note.isDeleted, note.isVisible(in: AuthManager.shared.activeScope) else { return nil }
        return note
    }
    @State private var loaded = false

    var body: some View {
        Group {
            if let note = liveNote {
                VStack(spacing: 0) {
                    NoteToolbarView(
                        note: note,
                        proxy: editorProxy,
                        audioRecorder: audioRecorder,
                        speechRecognizer: speechRecognizer,
                        onDelete: { requestDelete() },
                        onAudioSaved: { data in
                            note.addAudioRecording(data)
                            try? modelContext.save()
                            SyncEngine.shared.scheduleDebouncedPush(for: note.id, in: modelContext)
                        },
                        onStartDictation: { startLiveDictation() },
                        onStopDictation: { stopLiveDictation() },
                        onCreateNote: { createNote() }
                    )

                    if note.recoveryPaused {
                        Text(String(localized: "Recovery paused — local content only"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if note.pendingCreateOperationID != nil {
                        Text(String(localized: "Creation result needs verification — automatic retry blocked"))
                            .font(.caption2).foregroundStyle(.orange)
                    }

                    NoteTextEditor(
                        attributedText: $attributedText,
                        plainText: $plainText,
                        backgroundColor: NSColor(note.noteColor.backgroundColor(for: colorScheme)),
                        proxy: editorProxy,
                        onTextChange: { saveContent() }
                    )

                    AudioClipView(
                        recordings: note.audioRecordings,
                        audioRecorder: audioRecorder,
                        onDelete: { index in
                            note.removeAudioRecording(at: index)
                            try? modelContext.save()
                            SyncEngine.shared.scheduleDebouncedPush(for: note.id, in: modelContext)
                        }
                    )
                }
                .background(
                    WindowAccessor(
                        noteID: noteID,
                        noteColor: note.noteColor,
                        windowFrame: NSRect(
                            x: note.windowX, y: note.windowY,
                            width: note.windowWidth, height: note.windowHeight
                        ),
                        onClose: {
                            audioRecorder.stopPlayback()
                            speechRecognizer.stopListening()
                            windowManager.markClosed(noteID)
                            if let note = liveNote {
                                note.isOpen = false
                                saveWindowPosition()
                            }
                        },
                        onFrameChanged: { frame in
                            guard let note = liveNote else { return }
                            note.windowX = Double(frame.origin.x)
                            note.windowY = Double(frame.origin.y)
                            note.windowWidth = Double(frame.size.width)
                            note.windowHeight = Double(frame.size.height)
                            try? modelContext.save()
                        }
                    )
                )
            } else {
                if AuthManager.shared.isRestoringSession || AuthManager.shared.activeScope == .blocked {
                    Color.clear
                        .frame(width: 300, height: 200)
                } else {
                    Text(String(localized: "Note not found"))
                        .frame(width: 300, height: 200)
                        // Out-of-scope (other account / signed out / identity unconfirmed) or deleted: close the window.
                        // `isOpen` is deliberately untouched so the window returns when its scope is active again.
                        .background(loaded ? AnyView(ScopeWindowCloser { windowManager.markClosed(noteID) }) : AnyView(EmptyView()))
                }
            }
        }
        .alert(String(localized: "Delete Note?"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Delete"), role: .destructive) { deleteNote() }
        } message: {
            Text(String(localized: "This note will be permanently deleted."))
        }
        .onAppear { loadNote() }
        .onChange(of: AuthManager.shared.activeScope) { _, newScope in
            if newScope != .blocked { loadNote() }
        }
        .onChange(of: AuthManager.shared.restoreState) { _, newRestoreState in
            if newRestoreState == .done { loadNote() }
        }
        .onChange(of: note?.modifiedAt) { _, _ in
            syncFromModelIfExternalChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatBold)) { _ in
            if editorProxy.textView?.window?.isKeyWindow == true {
                editorProxy.toggleBold()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatItalic)) { _ in
            if editorProxy.textView?.window?.isKeyWindow == true {
                editorProxy.toggleItalic()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatUnderline)) { _ in
            if editorProxy.textView?.window?.isKeyWindow == true {
                editorProxy.toggleUnderline()
            }
        }
    }

    // MARK: - Data

    private func loadNote() {
        let id = noteID
        let descriptor = FetchDescriptor<StickyNote>(
            predicate: #Predicate { $0.id == id }
        )
        defer { loaded = true }
        guard let found = try? modelContext.fetch(descriptor).first,
              found.isVisible(in: AuthManager.shared.activeScope) else { return }
        self.note = found

        if let data = found.attributedContentData {
            let classes = [NSAttributedString.self, NSFont.self, NSColor.self,
                          NSParagraphStyle.self, NSShadow.self, NSTextAttachment.self]
            if let restored = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSAttributedString {
                self.attributedText = restored
            } else {
                self.attributedText = NSAttributedString(string: found.plainTextContent)
            }
        } else {
            self.attributedText = NSAttributedString(string: found.plainTextContent)
        }
        self.plainText = found.plainTextContent
        windowManager.markOpened(noteID)
    }

    private func syncFromModelIfExternalChange() {
        guard let note = liveNote else { return }
        let isPlainDifferent = note.plainTextContent != self.plainText
        var newAttributed: NSAttributedString?
        var isAttributedDifferent = false

        if let data = note.attributedContentData {
            let classes = [NSAttributedString.self, NSFont.self, NSColor.self,
                          NSParagraphStyle.self, NSShadow.self, NSTextAttachment.self]
            if let restored = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSAttributedString {
                if !restored.isEqual(to: self.attributedText) {
                    isAttributedDifferent = true
                    newAttributed = restored
                }
            }
        } else if !self.plainText.isEmpty || !self.attributedText.string.isEmpty {
            let fallback = NSAttributedString(string: note.plainTextContent)
            if !fallback.isEqual(to: self.attributedText) {
                isAttributedDifferent = true
                newAttributed = fallback
            }
        }

        if isPlainDifferent || isAttributedDifferent {
            self.plainText = note.plainTextContent
            if let newAttributed {
                self.attributedText = newAttributed
            } else {
                self.attributedText = NSAttributedString(string: note.plainTextContent)
            }
        }
    }

    private func saveContent() {
        guard let note = liveNote else { return }
        guard let archivedText = try? NSKeyedArchiver.archivedData(
            withRootObject: attributedText,
            requiringSecureCoding: true
        ) else {
            SyncEngine.shared.state = .error("无法保存便笺格式；本次更改尚未同步。")
            return
        }
        let previousText = note.plainTextContent
        let previousAttributedText = note.attributedContentData
        let previousModifiedAt = note.modifiedAt
        let previousStatus = note.syncStatus
        note.plainTextContent = plainText
        note.attributedContentData = archivedText
        note.modifiedAt = Date()
        note.syncStatus = .pendingUpload
        do {
            try modelContext.save()
        } catch {
            // Keep the user's edits in the editor state, but don't let a failed local commit
            // become a cloud write. A later edit can retry the save.
            note.plainTextContent = previousText
            note.attributedContentData = previousAttributedText
            note.modifiedAt = previousModifiedAt
            note.syncStatus = previousStatus
            SyncEngine.shared.state = .error("无法保存便笺：\(error.localizedDescription)")
            return
        }
        SyncEngine.shared.scheduleDebouncedPush(for: note.id, in: modelContext)
    }

    // MARK: - Window Position

    private func saveWindowPosition() {
        guard let note = liveNote else { return }
        if let frame = windowManager.windowFrame(for: noteID) {
            note.windowX = Double(frame.origin.x)
            note.windowY = Double(frame.origin.y)
            note.windowWidth = Double(frame.size.width)
            note.windowHeight = Double(frame.size.height)
        }
        try? modelContext.save()
    }

    // MARK: - Dictation

    private func startLiveDictation() {
        guard let textView = editorProxy.textView else { return }
        let cursor = textView.selectedRange()
        var anchor = cursor.location

        if anchor > 0 {
            let prevChar = (textView.string as NSString).substring(with: NSRange(location: anchor - 1, length: 1))
            if prevChar != " " && prevChar != "\n" {
                textView.insertText(" ", replacementRange: NSRange(location: anchor, length: 0))
                anchor += 1
            }
        }

        dictationAnchor = anchor
        dictationLength = 0

        speechRecognizer.onPartialResult = { [self] partialText in
            guard let textView = editorProxy.textView,
                  let anchor = dictationAnchor else { return }
            let replaceRange = NSRange(location: anchor, length: dictationLength)
            textView.insertText(partialText, replacementRange: replaceRange)
            dictationLength = (partialText as NSString).length
            textView.setSelectedRange(NSRange(location: anchor + dictationLength, length: 0))
        }

        speechRecognizer.requestAuthorization { authorized in
            if authorized { speechRecognizer.startListening() }
        }
    }

    private func stopLiveDictation() {
        speechRecognizer.onPartialResult = nil
        speechRecognizer.stopListening()
        dictationAnchor = nil
        dictationLength = 0
        saveContent()
    }

    // MARK: - Create

    private func createNote() {
        let rawColor = UserDefaults.standard.string(forKey: "defaultColor") ?? NoteColor.yellow.rawValue
        let color = NoteColor.fromPersisted(rawColor)
        guard let newNote = StickyNote.make(in: AuthManager.shared.activeScope, color: color) else { NSSound.beep(); return }
        modelContext.insert(newNote)
        try? modelContext.save()
        openWindow(value: newNote.id)
    }

    // MARK: - Delete

    private func requestDelete() {
        if confirmBeforeDelete {
            showDeleteConfirmation = true
        } else {
            deleteNote()
        }
    }

    private func deleteNote() {
        guard let noteToDelete = note else { return }
        do { try SyncEngine.shared.prepareForDeletion(noteToDelete, modelContext: modelContext) }
        catch { SyncEngine.shared.state = .error(error.localizedDescription); return }
        let remoteId = noteToDelete.remoteId
        audioRecorder.stopPlayback()
        speechRecognizer.stopListening()
        self.note = nil
        windowManager.closeWindow(for: noteID)
        if noteToDelete.requiresRemoteCleanup {
            noteToDelete.isDeletedLocally = true
            noteToDelete.syncStatus = .error
            try? modelContext.save()
            if let remoteId {
                SyncEngine.shared.deleteRemoteNote(remoteId: remoteId, ownerAccountID: noteToDelete.ownerAccountID)
            }
        } else {
            modelContext.delete(noteToDelete)
            try? modelContext.save()
        }
    }
}

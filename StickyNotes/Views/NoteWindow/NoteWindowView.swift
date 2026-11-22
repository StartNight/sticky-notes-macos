import SwiftUI
import SwiftData

struct NoteWindowView: View {
    let noteID: UUID
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(WindowManager.self) private var windowManager
    @Environment(ActiveWindowTracker.self) private var activeWindowTracker
    @State private var note: StickyNote?
    @State private var attributedText = NSAttributedString()
    @State private var plainText = ""
    @State private var externalSyncVersion = 0
    @State private var hasUnsavedLocalChanges = false
    @State private var lastLocalSaveModifiedAt: Date?
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var pendingFrameSaveTask: Task<Void, Never>?
    @State private var initialWindowFrame: NSRect?
    @State private var editorProxy = TextEditorProxy()
    @State private var audioRecorder = AudioRecorder()
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var showDeleteConfirmation = false
    @State private var dictationAnchor: Int?
    @State private var dictationLength: Int = 0
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete = true

    /// The note if it is still backed by a live, non-tombstoned SwiftData model in the active scope.
    private var liveNote: StickyNote? {
        guard let note, !note.isDeleted, !note.isDeletedLocally,
              note.isVisible(in: AuthManager.shared.activeScope) else { return nil }
        return note
    }
    @State private var loaded = false

    private static var defaultTextAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor
        ]
    }

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
                            guard let activeNote = liveNote else { return }
                            activeNote.addAudioRecording(data)
                            lastLocalSaveModifiedAt = activeNote.modifiedAt
                            do {
                                try modelContext.save()
                                SyncEngine.shared.scheduleDebouncedPush(for: activeNote.id, in: modelContext)
                            } catch {
                                SyncEngine.shared.state = .error("无法保存录音：\(error.localizedDescription)")
                            }
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
                        externalSyncVersion: externalSyncVersion,
                        backgroundColor: NSColor(note.noteColor.backgroundColor(for: colorScheme)),
                        proxy: editorProxy,
                        onTextChange: { scheduleLocalSave() }
                    )

                    AudioClipView(
                        recordings: note.audioRecordings,
                        audioRecorder: audioRecorder,
                        onDelete: { index in
                            guard let activeNote = liveNote,
                                  activeNote.audioRecordings.indices.contains(index) else { return }
                            if audioRecorder.playingIndex == index {
                                audioRecorder.stopPlayback()
                            } else if let playing = audioRecorder.playingIndex, index < playing {
                                audioRecorder.playingIndex = playing - 1
                            }
                            activeNote.removeAudioRecording(at: index)
                            lastLocalSaveModifiedAt = activeNote.modifiedAt
                            do {
                                try modelContext.save()
                                SyncEngine.shared.scheduleDebouncedPush(for: activeNote.id, in: modelContext)
                            } catch {
                                SyncEngine.shared.state = .error("无法保存录音更改：\(error.localizedDescription)")
                            }
                        }
                    )
                }
                .background(
                    WindowAccessor(
                        noteID: noteID,
                        noteColor: note.noteColor,
                        windowFrame: initialWindowFrame ?? NSRect(
                            x: note.windowX, y: note.windowY,
                            width: note.windowWidth, height: note.windowHeight
                        ),
                        onClose: {
                            flushPendingLocalSave()
                            flushPendingFrameSave()
                            audioRecorder.cancelRecording()
                            audioRecorder.stopPlayback()
                            stopLiveDictation(saveAfterStop: false)
                            windowManager.markClosed(noteID)
                            if let note = liveNote {
                                note.isOpen = false
                                saveWindowPosition()
                            }
                        },
                        onFrameChanged: { frame in
                            guard !activeWindowTracker.isRepositioning else { return }
                            scheduleFrameSave(frame)
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
        .onAppear {
            activeWindowTracker.isEnabled = UserDefaults.standard.object(forKey: "followActiveApp") as? Bool ?? true
            activeWindowTracker.start()
            loadNote()
        }
        .onDisappear {
            flushPendingLocalSave()
            flushPendingFrameSave()
            audioRecorder.cancelRecording()
            audioRecorder.stopPlayback()
            stopLiveDictation(saveAfterStop: false)
        }
        .onChange(of: AuthManager.shared.activeScope) { _, newScope in
            if newScope != .blocked { loadNote() }
        }
        .onChange(of: AuthManager.shared.restoreState) { _, newRestoreState in
            if newRestoreState == .done { loadNote() }
        }
        .onChange(of: note?.modifiedAt) { _, _ in
            syncFromModelIfExternalChange()
        }
        .onChange(of: note?.changeKey) { _, _ in
            syncFromModelIfExternalChange()
        }
        .onChange(of: note?.lastSyncedAt) { _, _ in
            syncFromModelIfExternalChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatBold)) { _ in
            if isNoteEditorFocusedInKeyWindow {
                editorProxy.toggleBold()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatItalic)) { _ in
            if isNoteEditorFocusedInKeyWindow {
                editorProxy.toggleItalic()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatUnderline)) { _ in
            if isNoteEditorFocusedInKeyWindow {
                editorProxy.toggleUnderline()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatStrikethrough)) { _ in
            if isNoteEditorFocusedInKeyWindow {
                editorProxy.toggleStrikethrough()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatBulletList)) { _ in
            if isNoteEditorFocusedInKeyWindow {
                editorProxy.toggleBulletList()
            }
        }
    }

    /// True only when this note's window is key and focus is NOT inside a secondary text field (e.g. Find bar).
    private var isNoteEditorFocusedInKeyWindow: Bool {
        guard let tv = editorProxy.textView, let window = tv.window, window.isKeyWindow else { return false }
        if let responder = window.firstResponder as? NSTextView, responder !== tv {
            return false
        }
        return true
    }

    // MARK: - Data

    private func loadNote() {
        // Never mark `loaded = true` while startup restore is still pending or scope is blocked,
        // otherwise `ScopeWindowCloser` could prematurely close a valid restored note window.
        guard !AuthManager.shared.isRestoringSession, AuthManager.shared.activeScope != .blocked else {
            return
        }
        let id = noteID
        let descriptor = FetchDescriptor<StickyNote>(
            predicate: #Predicate { $0.id == id }
        )
        defer { loaded = true }
        guard let found = try? modelContext.fetch(descriptor).first,
              !found.isDeleted, !found.isDeletedLocally,
              found.isVisible(in: AuthManager.shared.activeScope) else { return }
        self.note = found
        self.initialWindowFrame = NSRect(x: found.windowX, y: found.windowY, width: found.windowWidth, height: found.windowHeight)
        if !found.isOpen {
            found.isOpen = true
            try? modelContext.save()
        }

        if let data = found.attributedContentData {
            let classes = [NSAttributedString.self, NSFont.self, NSColor.self,
                          NSParagraphStyle.self, NSShadow.self, NSTextAttachment.self]
            if let restored = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSAttributedString {
                self.attributedText = restored
            } else {
                self.attributedText = NSAttributedString(string: found.plainTextContent, attributes: Self.defaultTextAttributes)
            }
        } else {
            self.attributedText = NSAttributedString(string: found.plainTextContent, attributes: Self.defaultTextAttributes)
        }
        self.plainText = found.plainTextContent
        self.hasUnsavedLocalChanges = false
        self.externalSyncVersion += 1
        windowManager.markOpened(noteID)
    }

    private func syncFromModelIfExternalChange() {
        guard let note = liveNote else { return }
        // Ignore model notifications triggered by our own local save, or while local edits / IME are pending.
        if hasUnsavedLocalChanges { return }
        if let lastLocal = lastLocalSaveModifiedAt, note.modifiedAt == lastLocal {
            return
        }
        if editorProxy.textView?.hasMarkedText() == true { return }

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
            let fallback = NSAttributedString(string: note.plainTextContent, attributes: Self.defaultTextAttributes)
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
                self.attributedText = NSAttributedString(string: note.plainTextContent, attributes: Self.defaultTextAttributes)
            }
            self.externalSyncVersion += 1
        }
    }

    private func scheduleLocalSave() {
        hasUnsavedLocalChanges = true
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            saveContent()
        }
    }

    private func flushPendingLocalSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        if hasUnsavedLocalChanges {
            saveContent()
        }
    }

    private func saveContent() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        guard let note = liveNote else { return }
        let safeAttr = ClickableTextView.sanitizeAttributedString(attributedText)
        guard let archivedText = try? NSKeyedArchiver.archivedData(
            withRootObject: safeAttr,
            requiringSecureCoding: true
        ) else {
            SyncEngine.shared.state = .error("无法保存便笺格式；本次更改尚未同步。")
            return
        }
        let previousText = note.plainTextContent
        let previousAttributedText = note.attributedContentData
        let previousModifiedAt = note.modifiedAt
        let previousStatus = note.syncStatus
        let now = Date()
        note.plainTextContent = plainText
        note.attributedContentData = archivedText
        note.modifiedAt = now
        if !note.recoveryPaused && note.pendingCreateOperationID == nil && !note.hasCorruptSyncJournal && !note.hasCorruptRecoveryJournal {
            note.syncStatus = .pendingUpload
        }
        lastLocalSaveModifiedAt = now
        do {
            try modelContext.save()
            hasUnsavedLocalChanges = false
        } catch {
            // Keep the user's edits in the editor state, and keep `hasUnsavedLocalChanges = true`
            // so a subsequent sync/color update does not overwrite the unsaved edits.
            note.plainTextContent = previousText
            note.attributedContentData = previousAttributedText
            note.modifiedAt = previousModifiedAt
            note.syncStatus = previousStatus
            lastLocalSaveModifiedAt = nil
            SyncEngine.shared.state = .error("无法保存便笺：\(error.localizedDescription)")
            return
        }
        SyncEngine.shared.scheduleDebouncedPush(for: note.id, in: modelContext)
    }

    // MARK: - Window Position

    private func scheduleFrameSave(_ frame: NSRect) {
        pendingFrameSaveTask?.cancel()
        pendingFrameSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            persistWindowFrame(frame)
        }
    }

    private func flushPendingFrameSave() {
        pendingFrameSaveTask?.cancel()
        pendingFrameSaveTask = nil
    }

    private func persistWindowFrame(_ frame: NSRect) {
        guard let note = liveNote,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite else { return }
        note.windowX = Double(frame.origin.x)
        note.windowY = Double(frame.origin.y)
        note.windowWidth = Double(frame.size.width)
        note.windowHeight = Double(frame.size.height)
        try? modelContext.save()
    }

    private func saveWindowPosition() {
        guard let note = liveNote else { return }
        if let frame = windowManager.windowFrame(for: noteID) {
            persistWindowFrame(frame)
        } else {
            try? modelContext.save()
        }
    }

    // MARK: - Dictation

    private func startLiveDictation() {
        guard editorProxy.textView != nil, liveNote != nil else { return }
        // Mutual exclusion with audio recording/playback so mic input isn't contended.
        audioRecorder.stopPlayback()
        if audioRecorder.isRecording {
            audioRecorder.cancelRecording()
        }

        speechRecognizer.requestAuthorization { authorized in
            guard authorized,
                  let textView = editorProxy.textView,
                  textView.window != nil,
                  liveNote != nil else { return }

            let nsString = textView.string as NSString
            let cursor = textView.selectedRange()
            var anchor = cursor.location == NSNotFound ? nsString.length : min(cursor.location, nsString.length)

            if anchor > 0 && anchor <= nsString.length {
                let prevChar = nsString.substring(with: NSRange(location: anchor - 1, length: 1))
                if prevChar != " " && prevChar != "\n" {
                    textView.insertText(" ", replacementRange: NSRange(location: anchor, length: 0))
                    anchor = min(anchor + 1, (textView.string as NSString).length)
                }
            }

            dictationAnchor = anchor
            dictationLength = 0

            speechRecognizer.onPartialResult = { partialText in
                guard let textView = editorProxy.textView,
                      let rawAnchor = dictationAnchor else { return }
                let currentLen = (textView.string as NSString).length
                let safeAnchor = min(max(0, rawAnchor), currentLen)
                let safeLength = min(max(0, dictationLength), currentLen - safeAnchor)
                let replaceRange = NSRange(location: safeAnchor, length: safeLength)
                textView.insertText(partialText, replacementRange: replaceRange)
                let insertedLen = (partialText as NSString).length
                dictationAnchor = safeAnchor
                dictationLength = insertedLen
                let postLen = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: min(safeAnchor + insertedLen, postLen), length: 0))
            }

            speechRecognizer.startListening()
        }
    }

    private func stopLiveDictation(saveAfterStop: Bool = true) {
        speechRecognizer.onPartialResult = nil
        speechRecognizer.stopListening()
        dictationAnchor = nil
        dictationLength = 0
        if saveAfterStop {
            saveContent()
        }
    }

    // MARK: - Create

    private func createNote() {
        let rawColor = UserDefaults.standard.string(forKey: "defaultColor") ?? NoteColor.yellow.rawValue
        let color = NoteColor.fromPersisted(rawColor)
        guard let newNote = StickyNote.make(in: AuthManager.shared.activeScope, color: color) else { NSSound.beep(); return }
        newNote.isOpen = true
        modelContext.insert(newNote)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(newNote)
            NSSound.beep()
            SyncEngine.shared.state = .error("无法创建便笺：\(error.localizedDescription)")
            return
        }
        windowManager.markOpened(newNote.id)
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
        guard let noteToDelete = liveNote else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        hasUnsavedLocalChanges = false
        flushPendingFrameSave()
        audioRecorder.cancelRecording()
        audioRecorder.stopPlayback()
        stopLiveDictation(saveAfterStop: false)
        self.note = nil
        windowManager.closeWindow(for: noteID)
        do {
            try SyncEngine.shared.requestDeletion(of: noteToDelete, in: modelContext)
        } catch {
            SyncEngine.shared.state = .error(error.localizedDescription)
        }
    }
}

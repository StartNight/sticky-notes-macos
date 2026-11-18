import SwiftUI

struct NoteToolbarView: View {
    let note: StickyNote
    let proxy: TextEditorProxy
    let audioRecorder: AudioRecorder
    let speechRecognizer: SpeechRecognizer
    let onDelete: () -> Void
    let onAudioSaved: (Data) -> Void
    let onStartDictation: () -> Void
    let onStopDictation: () -> Void
    let onCreateNote: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var showNoteMenu = false

    var body: some View {
        HStack(spacing: 4) {
            FormattingBar(
                onBold: { proxy.toggleBold() },
                onItalic: { proxy.toggleItalic() },
                onUnderline: { proxy.toggleUnderline() },
                onStrikethrough: { proxy.toggleStrikethrough() },
                onBulletList: { proxy.toggleBulletList() },
                onTodoList: { proxy.toggleTodoList() },
                onHiddenText: { proxy.toggleHiddenText() }
            )

            Spacer()

            if audioRecorder.isRecording {
                recordingIndicator
            } else if speechRecognizer.isListening {
                dictationIndicator
            } else {
                audioMenu
            }

            noteMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(note.noteColor.toolbarColor(for: colorScheme))
    }

    private var recordingIndicator: some View {
        HStack(spacing: 4) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text(audioRecorder.recordingDuration.formattedDuration)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.red)
            Button {
                if let data = audioRecorder.stopRecording() { onAudioSaved(data) }
            } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 14)).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    private var dictationIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 11)).foregroundStyle(.blue)
                .symbolEffect(.variableColor.iterative)
            Text(String(localized: "Listening..."))
                .font(.system(size: 10)).foregroundStyle(.blue)
            Button { onStopDictation() } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 14)).foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private var audioMenu: some View {
        Menu {
            Button { onStartDictation() } label: {
                Label(String(localized: "Dictate (Speech to Text)"), systemImage: "text.bubble")
            }
            Button { audioRecorder.startRecording() } label: {
                Label(String(localized: "Record Audio Clip"), systemImage: "waveform.circle")
            }
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(String(localized: "Audio Input"))
        .help(String(localized: "Audio Input"))
    }

    private var noteMenu: some View {
        Button {
            showNoteMenu.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Note Options"))
        .accessibilityIdentifier("note-options-menu")
        .accessibilityAddTraits(.isButton)
        .help(String(localized: "Note Options"))
        .popover(isPresented: $showNoteMenu, arrowEdge: .bottom) {
            noteMenuContent
        }
    }

    private var noteMenuContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showNoteMenu = false
                onCreateNote()
            } label: {
                Label(String(localized: "New Note"), systemImage: "plus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "New Note"))
            .accessibilityIdentifier("new-note")

            Divider()

            ColorPickerMenu(currentColor: note.noteColor) { color in
                note.setColor(color)
                if let context = note.modelContext {
                    try? context.save()
                    SyncEngine.shared.scheduleDebouncedPush(for: note.id, in: context)
                }
                showNoteMenu = false
            }

            Divider()

            Button(role: .destructive) {
                showNoteMenu = false
                onDelete()
            } label: {
                Label(String(localized: "Delete Note"), systemImage: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Delete Note"))
            .accessibilityIdentifier("delete-note")
        }
        .padding(12)
        .frame(minWidth: 180)
    }
}

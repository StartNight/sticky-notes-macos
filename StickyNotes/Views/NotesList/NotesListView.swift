import SwiftUI
import SwiftData

struct NotesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(WindowManager.self) private var windowManager
    @Environment(ActiveWindowTracker.self) private var activeWindowTracker
    @Query(sort: \StickyNote.modifiedAt, order: .reverse) private var notes: [StickyNote]
    @State private var authManager = AuthManager.shared
    @State private var syncEngine = SyncEngine.shared
    @State private var searchText = ""
    @State private var noteToDelete: StickyNote?
    @State private var showDeleteConfirmation = false
    @State private var showSyncPopover = false
    @State private var isCollapsed = false
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete = true
    @AppStorage("followActiveApp") private var followActiveApp = true

    private var filteredNotes: [StickyNote] {
        let visible = StickyNote.visibleNewestFirst(Array(notes))
        if searchText.isEmpty { return visible }
        let query = searchText.lowercased()
        return visible.filter { $0.plainTextContent.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SearchBar(text: $searchText)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            if filteredNotes.isEmpty {
                emptyState
            } else {
                notesList
            }
        }
        .frame(minWidth: 280, idealWidth: 320, minHeight: 400)
        .background(Color(.windowBackgroundColor))
        .onChange(of: followActiveApp) { _, newValue in
            activeWindowTracker.isEnabled = newValue
        }
        .onAppear {
            activeWindowTracker.isEnabled = followActiveApp
        }
        .task {
            if authManager.isAuthenticated {
                await syncEngine.syncAll(modelContext: modelContext)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestModelContextSync)) { _ in
            Task {
                await syncEngine.syncAll(modelContext: modelContext)
            }
        }
        .alert(String(localized: "Delete Note?"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) { noteToDelete = nil }
            Button(String(localized: "Delete"), role: .destructive) {
                if let note = noteToDelete { deleteNote(note) }
                noteToDelete = nil
            }
        } message: {
            Text(String(localized: "This note will be permanently deleted."))
        }
    }

    private var header: some View {
        HStack {
            Text(String(localized: "Sticky Notes"))
                .font(.system(size: 18, weight: .bold))

            Spacer()

            cloudSyncButton

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                Image(systemName: isCollapsed ? "list.bullet" : "rectangle.grid.1x2")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? String(localized: "Expanded View") : String(localized: "Compact View"))

            Button { createNote() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help(String(localized: "New Note (⌘N)"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var cloudSyncButton: some View {
        Button {
            showSyncPopover.toggle()
        } label: {
            Group {
                switch syncEngine.state {
                case .syncing:
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blue)
                        .rotationEffect(.degrees(360))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: syncEngine.state)
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                case .offline:
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                case .idle:
                    if authManager.isAuthenticated {
                        Image(systemName: "checkmark.icloud")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "icloud")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Microsoft Cloud Sync"))
        .popover(isPresented: $showSyncPopover, arrowEdge: .bottom) {
            syncPopoverContent
        }
    }

    private var syncPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                Text(String(localized: "Microsoft Sticky Notes"))
                    .font(.system(size: 14, weight: .semibold))
            }

            Divider()

            if authManager.isAuthenticated {
                VStack(alignment: .leading, spacing: 6) {
                    if let name = authManager.userName {
                        Text(name)
                            .font(.system(size: 13, weight: .medium))
                    }
                    if let email = authManager.userEmail {
                        Text(email)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(syncEngine.state == .syncing ? .blue : (syncEngine.state == .error("") ? .orange : .green))
                            .frame(width: 6, height: 6)
                        Text(syncEngine.state.displayText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)

                    if let lastSync = syncEngine.lastSyncDate {
                        Text(String(localized: "Last synced: \(lastSync.noteListFormatted)"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                HStack {
                    Button(String(localized: "Sync Now")) {
                        Task {
                            await syncEngine.syncAll(modelContext: modelContext)
                        }
                    }
                    .disabled(syncEngine.state == .syncing)

                    Spacer()

                    Button(String(localized: "Sign Out"), role: .destructive) {
                        authManager.signOut()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Connect your Microsoft account to sync sticky notes across Windows, Outlook, and macOS."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = authManager.lastAuthError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task {
                            try? await authManager.signIn()
                            if authManager.isAuthenticated {
                                await syncEngine.syncAll(modelContext: modelContext)
                            }
                        }
                    } label: {
                        HStack {
                            if authManager.isAuthenticating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "person.badge.key")
                            }
                            Text(authManager.isAuthenticating ? String(localized: "Signing in...") : String(localized: "Sign in with Microsoft"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(authManager.isAuthenticating)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? String(localized: "No notes yet") : String(localized: "No matching notes"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Text(String(localized: "Click + to create a new note"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var notesList: some View {
        ScrollView {
            LazyVStack(spacing: isCollapsed ? 4 : 8) {
                ForEach(filteredNotes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        if note.recoveryPaused {
                            Text(String(localized: "Recovery paused — local content only"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if note.pendingCreateOperationID != nil {
                            Text(String(localized: "Creation result needs verification — automatic retry blocked"))
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if note.ownerAccountID == nil || note.ownerAccountID != authManager.accountID {
                            Text(String(localized: "Not linked to current account — kept locally"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        NoteCardView(
                        note: note,
                        isCollapsed: isCollapsed,
                        onOpen: { openNote(note) },
                        onDelete: { requestDelete(note) }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func createNote() {
        let color = NoteColor.allCases.randomElement() ?? .yellow
        let note = StickyNote(color: color, ownerAccountID: AuthManager.shared.accountID)
        modelContext.insert(note)
        try? modelContext.save()
        openNote(note)
        if authManager.isAuthenticated {
            syncEngine.scheduleDebouncedPush(for: note.id, in: modelContext)
        }
    }

    private func openNote(_ note: StickyNote) {
        if windowManager.isOpen(note.id) {
            windowManager.bringToFront(note.id)
        } else {
            note.isOpen = true
            windowManager.markOpened(note.id)
            openWindow(value: note.id)
        }
    }

    private func requestDelete(_ note: StickyNote) {
        if confirmBeforeDelete {
            noteToDelete = note
            showDeleteConfirmation = true
        } else {
            deleteNote(note)
        }
    }

    private func deleteNote(_ note: StickyNote) {
        do { try syncEngine.prepareForDeletion(note, modelContext: modelContext) }
        catch { syncEngine.state = .error(error.localizedDescription); return }
        windowManager.closeWindow(for: note.id)
        let remoteId = note.remoteId
        if note.requiresRemoteCleanup {
            note.isDeletedLocally = true
            note.syncStatus = .error
            try? modelContext.save()
            if let remoteId {
                syncEngine.deleteRemoteNote(remoteId: remoteId, ownerAccountID: note.ownerAccountID)
            }
        } else {
            modelContext.delete(note)
            try? modelContext.save()
        }
    }
}

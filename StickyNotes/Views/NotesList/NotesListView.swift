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

    /// Strict account isolation: list and search only ever see the active scope.
    private var scope: ActiveScope { authManager.activeScope }

    private var filteredNotes: [StickyNote] {
        NoteScopeQuery.search(Array(notes), text: searchText, in: scope)
    }

    private var hiddenDataHint: String? {
        let all = Array(notes)
        let quarantined = NoteScopeQuery.quarantined(all).count
        let unlinked = scope.accountID == nil ? 0 : NoteScopeQuery.unlinked(all).count
        guard quarantined + unlinked > 0, scope != .blocked else { return nil }
        return String(localized: "Some local notes belong to another scope and are hidden. Manage them in Settings → Local Data.")
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
        .onChange(of: scope) { _, newScope in applyScopeChange(newScope) }
        .alert(String(localized: "Keychain access needed"), isPresented: Binding(get: { authManager.needsKeychainExplanation }, set: { _ in })) {
            Button(String(localized: "Continue")) { Task { await authManager.confirmKeychainAccess() } }
            Button(String(localized: "Not Now"), role: .cancel) { authManager.declineKeychainAccess() }
        } message: {
            Text(String(localized: "macOS may show the keychain prompt twice. Please choose Always Allow both times. Choosing Deny or Cancel deletes nothing, and the app will not ask again until you restart it."))
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

    // The first-sign-in adoption question lives in AdoptionPromptCoordinator (app level, window-independent).

    /// Windows follow the scope: out-of-scope note windows close (their isOpen flag is kept), and windows of
    /// notes that were open when this scope was last active come back.
    private func applyScopeChange(_ newScope: ActiveScope) {
        let all = (try? modelContext.fetch(FetchDescriptor<StickyNote>())) ?? []
        let plan = NoteScopeQuery.windowPlan(notes: all, scope: newScope, openWindowIDs: windowManager.openNoteIDs)
        plan.toClose.forEach { windowManager.closeWindow(for: $0) }
        for id in plan.toRestore {
            windowManager.markOpened(id)
            openWindow(value: id)
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
            .disabled(scope == .blocked)
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
                            .fill(syncEngine.state.statusColor)
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
            Text(scope == .blocked ? String(localized: "Confirming your Microsoft account… no notes are shown until the identity is verified.")
                 : searchText.isEmpty ? String(localized: "No notes yet") : String(localized: "No matching notes"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            if scope == .blocked, authManager.isAuthenticated, !authManager.isAuthenticating {
                Button(String(localized: "Retry Identity Check")) {
                    Task { _ = try? await authManager.ensureAccountID() }
                }
            }
            if let hint = hiddenDataHint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 16)
            }
            if searchText.isEmpty && scope != .blocked {
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
        let rawColor = UserDefaults.standard.string(forKey: "defaultColor") ?? NoteColor.yellow.rawValue
        let color = NoteColor.fromPersisted(rawColor)
        // Owner is stamped at creation; nothing is created while identity is unconfirmed.
        guard let note = StickyNote.make(in: scope, color: color) else { NSSound.beep(); return }
        modelContext.insert(note)
        try? modelContext.save()
        openNote(note)
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

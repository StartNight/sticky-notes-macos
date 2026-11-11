import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct LocalExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Where data outside the active account scope is managed. Nothing here is automatic:
/// every claim / copy / export is an explicit per-item (or per-bucket) user action, and nothing talks to Graph.
struct LocalDataSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allNotes: [StickyNote]
    @State private var authManager = AuthManager.shared
    @State private var syncEngine = SyncEngine.shared
    @State private var message: String?
    @State private var exportDocument: LocalExportDocument?
    @State private var showExporter = false
    @State private var pendingExport: (notes: [StickyNote], label: String)?
    @State private var confirmOutOfScopeExport = false
    private let service = AccountIsolationService.shared
    @State private var legacyKeychainStep = 0   // 0 idle, 1 first confirmation, 2 final confirmation

    private var scope: ActiveScope { authManager.activeScope }
    private var notes: [StickyNote] { Array(allNotes) }

    var body: some View {
        Form {
            Section(String(localized: "Current data scope")) {
                Text(scopeDescription).font(.caption)
                Button(String(localized: "Export visible notes…")) { requestExport(NoteScopeQuery.visible(notes, in: scope), label: "visible") }
                    .disabled(scope == .blocked)
                Text(String(localized: "Export works offline and signed out. It only writes to a file you choose and contains no login tokens."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            let unlinked = NoteScopeQuery.unlinked(notes)
            if !unlinked.isEmpty {
                Section(String(localized: "No-account notes")) {
                    Text(String(localized: "Created while signed out. They are never uploaded unless you move them into an account."))
                        .font(.caption).foregroundStyle(.secondary)
                    if scope.accountID != nil {
                        ForEach(unlinked) { note in
                            HStack {
                                Text(note.title).lineLimit(1)
                                Spacer()
                                Button(String(localized: "Sync to this account")) { run { _ = try service.adoptUnlinked(ids: [note.id], modelContext: modelContext) } }
                            }
                        }
                    } else {
                        Text(unlinkedCountText(unlinked.count))
                            .font(.caption)
                    }
                    Button(String(localized: "Export no-account notes…")) { requestExport(unlinked, label: "no-account") }
                }
            }

            let quarantined = NoteScopeQuery.quarantined(notes)
            if !quarantined.isEmpty {
                Section(String(localized: "Quarantine: unknown owner (older versions)")) {
                    Text(String(localized: "Saved by an older version that did not record the account. They are hidden everywhere and never assigned automatically."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(quarantined) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title).lineLimit(1)
                            if note.hasCloudTrace {
                                Text(String(localized: "Has cloud traces — owner could be any account. Copy keeps this original untouched."))
                                    .font(.caption2).foregroundStyle(.orange)
                                if scope.accountID != nil {
                                    Button(String(localized: "Copy to current account as new note")) {
                                        run { _ = try service.copyLegacyToCurrentAccount(note, modelContext: modelContext) }
                                    }
                                }
                            } else {
                                HStack {
                                    if scope.accountID != nil {
                                        Button(String(localized: "Move to current account")) { run { try service.claimLegacy(note, to: .currentAccount, modelContext: modelContext) } }
                                    }
                                    Button(String(localized: "Keep as no-account note")) { run { try service.claimLegacy(note, to: .noAccountLocal, modelContext: modelContext) } }
                                }
                            }
                        }
                    }
                    Button(String(localized: "Export quarantined notes…")) { requestExport(quarantined, label: "quarantine") }
                }
            }

            let foreign = NoteScopeQuery.foreignAccountCounts(notes, in: scope)
            if !foreign.isEmpty {
                Section(String(localized: "Other accounts' local data")) {
                    Text(String(localized: "Hidden while this scope is active. Only counts are shown."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(foreign.keys.sorted(), id: \.self) { owner in
                        HStack {
                            Text(foreignCountText(owner: owner, count: foreign[owner] ?? 0))
                            Spacer()
                            Button(String(localized: "Export…")) {
                                requestExport(notes.filter { $0.ownerAccountID == owner && !$0.isDeleted }, label: "other-account")
                            }
                        }
                    }
                }
            }

            Section(String(localized: "Old keychain entries")) {
                Text(String(localized: "Earlier versions stored sign-in tokens as separate keychain entries. Signing out never deletes them. Remove them here only if you no longer need them; the current sign-in is not affected."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(String(localized: "Remove old keychain entries…"), role: .destructive) { legacyKeychainStep = 1 }
            }

            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .alert(String(localized: "Remove old keychain entries?"), isPresented: Binding(get: { legacyKeychainStep == 1 }, set: { if !$0 && legacyKeychainStep == 1 { legacyKeychainStep = 0 } })) {
            Button(String(localized: "Cancel"), role: .cancel) { legacyKeychainStep = 0 }
            Button(String(localized: "Continue…"), role: .destructive) { legacyKeychainStep = 2 }
        } message: {
            Text(String(localized: "This deletes up to 5 old per-field sign-in entries (access/refresh token, expiry, email, name) left by earlier versions. Your notes and the current session are not touched."))
        }
        .alert(String(localized: "Really delete the old entries?"), isPresented: Binding(get: { legacyKeychainStep == 2 }, set: { if !$0 && legacyKeychainStep == 2 { legacyKeychainStep = 0 } })) {
            Button(String(localized: "Cancel"), role: .cancel) { legacyKeychainStep = 0 }
            Button(String(localized: "Delete Old Entries"), role: .destructive) {
                legacyKeychainStep = 0
                Task {
                    let ok = await KeychainHelper.shared.clearLegacyItemsAsync()
                    message = ok ? String(localized: "Old keychain entries removed.") : String(localized: "Some old keychain entries could not be removed.")
                }
            }
        } message: {
            Text(String(localized: "This cannot be undone."))
        }
        .formStyle(.grouped)
        .padding(8)
        .alert(String(localized: "Export data outside the current scope?"), isPresented: $confirmOutOfScopeExport) {
            Button(String(localized: "Cancel"), role: .cancel) { pendingExport = nil }
            Button(String(localized: "Export to a file I choose")) { performExport(acknowledged: true) }
        } message: {
            Text(String(localized: "This writes notes that do not belong to the current scope to a file you choose. Nothing is uploaded or changed."))
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json,
                      defaultFilename: "StickyNotes-LocalExport") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
    }

    private var scopeDescription: String {
        switch scope {
        case .blocked: return String(localized: "Identity not confirmed — no notes are shown or synced.")
        case .unlinkedLocal: return String(localized: "Signed out — only no-account notes are shown.")
        case .account: return String(localized: "Signed in — only this account's notes are shown.")
        }
    }

    private func unlinkedCountText(_ count: Int) -> String {
        let number = String(count)
        return String(localized: "\(number) note(s). Sign in to move them into an account.")
    }

    private func foreignCountText(owner: String, count: Int) -> String {
        let tail = String(owner.suffix(4))
        let number = String(count)
        return String(localized: "Account …\(tail): \(number) note(s)")
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); message = nil } catch { message = error.localizedDescription }
    }

    private func requestExport(_ list: [StickyNote], label: String) {
        pendingExport = (list, label)
        if list.contains(where: { !$0.isVisible(in: scope) }) { confirmOutOfScopeExport = true }
        else { performExport(acknowledged: false) }
    }

    private func performExport(acknowledged: Bool) {
        guard let pending = pendingExport else { return }
        pendingExport = nil
        do {
            exportDocument = LocalExportDocument(data: try LocalExporter.export(pending.notes, scope: scope, acknowledgedOutOfScope: acknowledged))
            showExporter = true
        } catch { message = error.localizedDescription }
    }
}

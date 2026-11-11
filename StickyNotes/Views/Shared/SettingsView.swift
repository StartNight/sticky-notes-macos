import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("defaultColor") private var defaultColor: String = NoteColor.yellow.rawValue
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete: Bool = true
    @AppStorage("followActiveApp") private var followActiveApp: Bool = true

    @State private var authManager = AuthManager.shared
    @State private var syncEngine = SyncEngine.shared
    @State private var isSigningIn = false
    @State private var errorMessage: String? = nil
    @State private var isSyncing = false
    @State private var confirmLocalUpload = false
    @State private var showRecovery = false
    @State private var adoptionAccountID: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label(String(localized: "General"), systemImage: "gearshape")
                }

            microsoftAccountTab
                .tabItem {
                    Label(String(localized: "Microsoft Account"), systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 450, height: 340)
        .sheet(isPresented: $showRecovery) { RecoveryReviewView().modelContainer(modelContext.container) }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Picker(String(localized: "Default note color"), selection: $defaultColor) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    HStack {
                        Circle()
                            .fill(color.background)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                        Text(color.displayName)
                    }
                    .tag(color.rawValue)
                }
            }

            Toggle(String(localized: "Confirm before deleting a note"), isOn: $confirmBeforeDelete)
            Toggle(String(localized: "Follow active app window"), isOn: $followActiveApp)
                .help(String(localized: "Automatically reposition notes below the active app window"))
        }
        .formStyle(.grouped)
        .padding(8)
    }

    // MARK: - Microsoft Account Tab

    private var microsoftAccountTab: some View {
        Form {
            if authManager.isAuthenticated {
                Section(String(localized: "Signed In Account")) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(authManager.userName ?? String(localized: "Microsoft Account"))
                                .font(.system(size: 14, weight: .semibold))
                            if let email = authManager.userEmail {
                                Text(email)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button(String(localized: "Sign Out")) {
                            authManager.signOut()
                            syncEngine.state = .offline
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(String(localized: "Synchronization")) {
                    Button(String(localized: "Recovery review (including deleted notes)")) { showRecovery = true }
                        .disabled(authManager.accountID == nil)
                    Text(String(localized: "Notes from other accounts and legacy unowned notes remain local and are not uploaded to this account."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(String(localized: "Upload unowned local-only notes to this account")) {
                        adoptionAccountID = authManager.accountID
                        confirmLocalUpload = true
                    }
                    .disabled(authManager.accountID == nil)
                    .confirmationDialog(String(localized: "Upload local-only notes?"), isPresented: $confirmLocalUpload) {
                        Button(String(localized: "Upload to current account")) {
                            do {
                                guard adoptionAccountID == authManager.accountID else { return }
                                _ = try syncEngine.adoptLocalOnlyNotes(modelContext: modelContext)
                                triggerManualSync()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    } message: {
                        Text(String(localized: "Only notes never linked to a remote account will be assigned. Legacy remote notes and other accounts' notes will not be changed."))
                    }
                    HStack {
                        Label {
                            Text(syncEngine.state.displayText)
                        } icon: {
                            Image(systemName: syncEngine.state.systemImage)
                                .foregroundStyle(syncEngine.state == .idle ? .green : .orange)
                        }

                        Spacer()

                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button(String(localized: "Sync Now")) {
                                triggerManualSync()
                            }
                        }
                    }

                    if let lastSync = syncEngine.lastSyncDate {
                        HStack {
                            Text(String(localized: "Last Synced:"))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(lastSync.formatted(date: .abbreviated, time: .standard))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    }
                }
            } else {
                Section(String(localized: "Account Connection")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "Connect your Microsoft account to enable bidirectional synchronization with Microsoft Sticky Notes across Windows, web, and mobile."))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }

                        HStack {
                            Button {
                                startSignIn()
                            } label: {
                                HStack {
                                    if isSigningIn {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.right.circle.fill")
                                    }
                                    Text(String(localized: "Sign In with Microsoft"))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSigningIn)

                            Spacer()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let authError = authManager.lastAuthError {
                Text(authError).foregroundStyle(.red)
            }
            Section(String(localized: "OAuth Configuration")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(localized: "Client ID:"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    TextField(String(localized: "Client ID"), text: Binding(
                        get: { authManager.clientId },
                        set: { authManager.clientId = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                    HStack {
                        Text(String(localized: "Redirect URI:"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    TextField(String(localized: "Redirect URI"), text: Binding(
                        get: { authManager.redirectUri },
                        set: { authManager.redirectUri = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private func startSignIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await authManager.signIn()
                isSigningIn = false
                triggerManualSync()
            } catch {
                isSigningIn = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func triggerManualSync() {
        guard !isSyncing else { return }
        isSyncing = true
        Task {
            await syncEngine.syncAll(modelContext: modelContext)
            isSyncing = false
        }
    }
}

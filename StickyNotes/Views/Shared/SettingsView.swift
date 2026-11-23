import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("defaultColor") private var defaultColor: String = NoteColor.yellow.rawValue
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete: Bool = true
    @AppStorage("followActiveApp") private var followActiveApp: Bool = true

    @State private var authManager = AuthManager.shared
    @State private var syncEngine = SyncEngine.shared
    @State private var errorMessage: String? = nil
    @State private var showRecovery = false

    private var normalizedDefaultColor: Binding<String> {
        Binding(
            get: { NoteColor.fromPersisted(defaultColor).rawValue },
            set: { defaultColor = $0 }
        )
    }

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

            LocalDataSettingsView()
                .tabItem {
                    Label(String(localized: "Local Data"), systemImage: "externaldrive")
                }
        }
        .frame(width: 520, height: 460)
        .onAppear {
            let normalized = NoteColor.fromPersisted(defaultColor).rawValue
            if defaultColor != normalized {
                defaultColor = normalized
            }
        }
        .sheet(isPresented: $showRecovery) { RecoveryReviewView().modelContainer(modelContext.container) }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Picker(String(localized: "Default note color"), selection: normalizedDefaultColor) {
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
                            errorMessage = nil
                            authManager.signOut()
                            syncEngine.resetForSignOut()
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(String(localized: "Synchronization")) {
                    Button(String(localized: "Recovery review (including deleted notes)")) { showRecovery = true }
                        .disabled(!authManager.isIdentityVerified || authManager.accountID == nil)
                    Text(String(localized: "Notes from other accounts, no-account notes and legacy unowned notes are hidden here and never uploaded to this account. Manage them under Local Data."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label {
                            Text(syncEngine.state.displayText)
                        } icon: {
                            Image(systemName: syncEngine.state.systemImage)
                                .foregroundStyle(syncEngine.state.statusColor)
                        }

                        Spacer()

                        if syncEngine.state == .syncing {
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
                                    if authManager.isAuthenticating {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.right.circle.fill")
                                    }
                                    Text(String(localized: "Sign In with Microsoft"))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(authManager.isAuthenticating)

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
                        Button(String(localized: "Reset Defaults")) {
                            authManager.resetOAuthConfiguration()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .disabled(authManager.isAuthenticated || authManager.isAuthenticating)
                    }
                    TextField(String(localized: "Client ID"), text: Binding(
                        get: { authManager.clientId },
                        set: { authManager.clientId = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(authManager.isAuthenticated || authManager.isAuthenticating)

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
                    .disabled(authManager.isAuthenticated || authManager.isAuthenticating)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private func startSignIn() {
        guard !authManager.isAuthenticating else { return }
        errorMessage = nil
        Task {
            do {
                try await authManager.signIn()
                triggerManualSync()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func triggerManualSync() {
        guard syncEngine.state != .syncing else { return }
        Task {
            await syncEngine.syncAll(modelContext: modelContext)
        }
    }
}

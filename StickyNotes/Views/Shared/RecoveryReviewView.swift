import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct RecoveryJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct RecoveryReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var allNotes: [StickyNote]
    @State private var engine = SyncEngine.shared
    @State private var selectedID: UUID?
    @State private var candidateID = ""
    @State private var kind: RecoveryRemoteKind = .graphNote
    @State private var candidate: VerifiedRecoveryCandidate?
    @State private var reason = ""
    @State private var acknowledged = false
    @State private var busy = false
    @State private var notice: String?
    @State private var showConfirmation = false
    @State private var confirmationAction: RecoveryAction = .restoreLocal
    @State private var confirmationSourceID: UUID?
    @State private var confirmationVersion = 0
    @State private var confirmationCandidate: VerifiedRecoveryCandidate?
    @State private var confirmationMessage = ""
    @State private var exportDocument: RecoveryJSONDocument?
    @State private var showExporter = false
    private var records: [StickyNote] { engine.recoveryRecords(from: allNotes) }
    private var selected: StickyNote? { records.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(String(localized: "Recovery review (including deleted notes)")).font(.headline)
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
            }
            Text(String(localized: "Exact IDs only. No automatic similarity matching or proof of non-creation. Actions require the original account, verification, and explicit confirmation."))
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(selection: $selectedID) {
                    ForEach(records) { note in
                        VStack(alignment: .leading) {
                            Text(note.title).lineLimit(1)
                            if note.isDeletedLocally { Text(String(localized: "Hidden tombstone — content retained")).font(.caption).foregroundStyle(.orange) }
                            if note.recoveryIsArchive { Text(String(localized: "Preserved local snapshot")).font(.caption) }
                            if note.recoveryPendingDeleteID != nil { Text(String(localized: "Deletion awaiting verification")).font(.caption).foregroundStyle(.orange) }
                        }.tag(note.id)
                    }
                }.frame(minWidth: 190, idealWidth: 220)
                ScrollView {
                    if let note = selected {
                        details(note).padding(8)
                    } else { Text(String(localized: "Select a recovery record from the original account.")).padding() }
                }.frame(minWidth: 440)
            }
            if busy { ProgressView() }
            if let notice { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .padding().frame(minWidth: 760, minHeight: 670)
        .onChange(of: selectedID) { _, _ in candidate = nil; candidateID = ""; acknowledged = false; notice = nil }
        .onChange(of: candidateID) { _, _ in candidate = nil }
        .onChange(of: kind) { _, _ in candidate = nil }
        .alert(String(localized: "Confirm recovery action"), isPresented: $showConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Confirm this exact action"), role: .destructive) { performConfirmedAction() }
        } message: { Text(confirmationMessage) }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json,
                      defaultFilename: "StickyNote-Recovery-" + (selectedID?.uuidString ?? "record")) { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
        }
    }
    private func details(_ note: StickyNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.title).font(.headline)
            Text("Local ID: " + note.id.uuidString).font(.caption).textSelection(.enabled)
            Text("Original Graph account ID: " + (note.ownerAccountID ?? "—")).font(.caption).textSelection(.enabled)
            Text("Operation: " + (note.pendingCreateOperationID ?? "—")).font(.caption).textSelection(.enabled)
            if let endpoint = note.pendingCreateEndpoint { Text(endpoint).font(.caption) }
            Text(note.plainTextContent).lineLimit(8).textSelection(.enabled)
            Button(String(localized: "Export retained content and recovery metadata…")) {
                do { exportDocument = RecoveryJSONDocument(data: try engine.exportRecoveryContent(note)); showExporter = true }
                catch { notice = error.localizedDescription }
            }.disabled(busy)
            Text(String(localized: "Export is optional and only writes to a location you choose. JSON includes rich text and audio, but no login tokens."))
                .font(.caption).foregroundStyle(.secondary)
            if !note.recoveryRetainedRemoteIDs.isEmpty {
                Text(String(localized: "Old remote IDs retained — never automatically deleted:")).font(.caption)
                ForEach(note.recoveryRetainedRemoteIDs, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
            }
            if let pending = note.recoveryPendingDeleteID { Text("Pending DELETE: " + pending).font(.caption).textSelection(.enabled) }
            candidatePanel(note)
            TextField(String(localized: "Verification evidence / reason (no passwords or tokens)"), text: $reason)
                .textFieldStyle(.roundedBorder)
            Toggle(String(localized: "I verified the original account and exact object, accept uncertainty, and authorize only the action I confirm."), isOn: $acknowledged)
                .font(.caption)
            actions(note)
            DisclosureGroup(String(localized: "Local recovery audit (not sent as logs)")) {
                ForEach(Array(note.recoveryAudit.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading) {
                        Text(entry.date.formatted() + " · " + entry.action).font(.caption)
                        Text(entry.reason).font(.caption).textSelection(.enabled)
                        if let id = entry.remoteID { Text(id).font(.caption).textSelection(.enabled) }
                    }.padding(.vertical, 3)
                }
            }
        }
    }
    private func candidatePanel(_ note: StickyNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Picker(String(localized: "Candidate resource type"), selection: $kind) {
                ForEach(RecoveryRemoteKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextField(String(localized: "Exact remote ID to verify"), text: $candidateID).textFieldStyle(.roundedBorder)
            Button(String(localized: "Verify ownership and preview (read only)")) {
                run { candidate = try await engine.verifyRecoveryCandidate(note, id: candidateID, kind: kind) }
            }.disabled(busy || candidateID.trimmingCharacters(in: .whitespaces).isEmpty)
            if let candidate {
                Text(candidate.exists ? String(localized: "Verified in the original account — manual relationship confirmation still required") : String(localized: "Previously authorized deletion target is absent — review before completing local recovery"))
                    .font(.caption).foregroundStyle(.secondary)
                Text("ID: " + candidate.id + " · changeKey: " + (candidate.changeKey ?? "—")).font(.caption).textSelection(.enabled)
                Text(NoteConverter.extractPlainText(from: candidate.html)).lineLimit(8).textSelection(.enabled)
            }
        }
    }
    private func actions(_ note: StickyNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(String(localized: "Restore visibility as paused local content")) { request(.restoreLocal, note: note) }
            if let candidate {
                Button(String(localized: "Associate verified object and resume (restore if deleted)")) { request(.associate, note: note) }
                    .disabled(!candidate.exists || note.recoveryPendingDeleteID != nil)
                if note.recoveryRetainedRemoteIDs.contains(candidate.id) {
                    Button(String(localized: "Delete only this verified retained old object…")) { request(.deleteRetained, note: note) }
                } else {
                    Button(String(localized: "Delete this verified candidate and keep content local…")) { request(.deleteCandidate, note: note) }
                }
            }
            Button(String(localized: "Explicitly create a new remote copy (duplicate risk)…")) { request(.retryCreate, note: note) }
                .disabled(note.recoveryPendingDeleteID != nil || (note.pendingCreateOperationID == nil && !note.recoveryPaused && note.syncStatus == .synced))
            Text(String(localized: "Association preserves local snapshots and archives other local representations without deleting cloud objects. Recreate can leave duplicates. Never infer absence from the first page or text similarity."))
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(busy || !acknowledged || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func request(_ action: RecoveryAction, note: StickyNote) {
        confirmationAction = action; confirmationSourceID = note.id; confirmationVersion = note.recoveryVersion
        confirmationCandidate = candidate
        let warning: String
        switch action {
        case .associate: warning = String(localized: "Link this exact verified object, restore visibility, and resume later updates. Preserve local snapshots and old references. No automatic cloud merge, deletion, or recreate.")
        case .deleteCandidate: warning = String(localized: "Delete exactly the verified remote object, then retain the source locally with sync paused. Other unknown copies are not automatically found or deleted.")
        case .deleteRetained: warning = String(localized: "Delete only this verified retained old ID. Do not resolve any separate unknown creation by guessing.")
        case .retryCreate: warning = String(localized: "You are authorizing a new POST in the original account. The old POST may already exist: duplicates or orphan objects are possible. Preserve old operation history and do not automatically delete old objects.")
        case .restoreLocal: warning = String(localized: "Restore local visibility with sync paused. Keep unknown creation markers and all audit records; do not write to Microsoft.")
        }
        let accountLine = "Account: " + (note.ownerAccountID ?? "—")
        let localLine = "Local: " + note.id.uuidString
        let remoteLine = "Remote: " + (candidate?.id ?? "new object / no remote write")
        confirmationMessage = [warning, accountLine, localLine, remoteLine].joined(separator: "\n")
        showConfirmation = true
    }
    private func performConfirmedAction() {
        guard let note = records.first(where: { $0.id == confirmationSourceID }) else { return }
        let action = confirmationAction, version = confirmationVersion, verified = confirmationCandidate
        run {
            switch action {
            case .restoreLocal: try await engine.restoreRecoveryLocalOnly(note, reason: reason, acknowledged: acknowledged)
            case .retryCreate: try await engine.retryRecoveryCreate(note, expectedVersion: version, reason: reason, acknowledged: acknowledged)
            default:
                guard let verified else { return }
                try await engine.confirmRecoveryCandidate(note, candidate: verified, action: action, reason: reason, acknowledged: acknowledged)
            }
            candidate = nil; acknowledged = false
            notice = String(localized: "Action recorded. Review retained references and sync status; this is not proof that all cloud copies are gone.")
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; notice = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { notice = error.localizedDescription }
        }
    }
}

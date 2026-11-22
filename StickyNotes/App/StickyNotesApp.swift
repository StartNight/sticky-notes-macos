import SwiftUI
import SwiftData

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioRecorder.cleanupOrphanTempFiles()
    }

    /// Keep app alive when the notes list window is closed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Always re-open the notes list when clicking the dock icon
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Always show the list window — floating note windows don't count as "the main window"
        if let window = sender.windows.first(where: Self.isNotesListWindow) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    private static func isNotesListWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == "notes-list" { return true }
        if window.level != .normal { return false }
        let titles: Set<String> = [
            String(localized: "Notes List"),
            String(localized: "Sticky Notes"),
            "Notes List",
            "Sticky Notes"
        ]
        return titles.contains(window.title)
    }
}

@main
struct StickyNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var windowManager = WindowManager()
    @State private var activeWindowTracker = ActiveWindowTracker()
    @Environment(\.openWindow) private var openWindow

    private static var hasRegisteredSyncObserver = false

    init() {
        // App-level, independent of whether the notes-list window exists: asks about no-account notes once the
        // account identity is verified (see AdoptionPromptCoordinator).
        let context = Self.sharedContainer.mainContext
        AdoptionPromptCoordinator.shared.start(
            context: context,
            presenter: AppKitAdoptionPromptPresenter(),
            accountLabel: { AuthManager.shared.userEmail ?? AuthManager.shared.userName ?? String(localized: "this account") },
            afterAccept: { context in await SyncEngine.shared.syncAll(modelContext: context) }
        )

        // Handle sync requests at the App level so background periodic sync and ⌘⇧S work
        // reliably even when the notes list window is closed and only floating note windows are open.
        if !Self.hasRegisteredSyncObserver {
            Self.hasRegisteredSyncObserver = true
            NotificationCenter.default.addObserver(forName: .requestModelContextSync, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    await SyncEngine.shared.syncAll(modelContext: Self.sharedContainer.mainContext)
                }
            }
        }
    }

    static let sharedContainer: ModelContainer = {
        let schema = Schema([StickyNote.self])
        let fileManager = FileManager.default
        // Prefer the legacy sandboxed container store if it exists so upgrading users keep their notes.
        let containerStore = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.shenanigans.sticky-notes/Data/Library/Application Support/default.store")
        let legacyRootStore = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        let appSupportDir = URL.applicationSupportDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.shenanigans.sticky-notes", isDirectory: true)
        let scopedStore = appSupportDir.appendingPathComponent("default.store")

        // Distinguish missing container store (ENOENT) from TCC denial (EPERM/EACCES) so we never
        // silently open a second split-brain store when macOS blocks container access.
        var statBuf = stat()
        let statResult = lstat(containerStore.path, &statBuf)
        let containerErrno = statResult == 0 ? 0 : errno
        if containerErrno == EPERM || containerErrno == EACCES {
            NSLog("STORE_OPEN_BLOCKED reason=tcc_container_denied errno=%d", containerErrno)
            presentFatalStoreError(
                message: "无法访问历史便笺容器目录（系统权限受限，错误码 \(containerErrno)）。为避免数据分裂，应用已停止启动；请在「系统设置 → 隐私与安全性」授予访问权限后重试。"
            )
        }

        let storeURL: URL
        if statResult == 0 {
            storeURL = containerStore
        } else if fileManager.fileExists(atPath: scopedStore.path) {
            storeURL = scopedStore
        } else if fileManager.fileExists(atPath: legacyRootStore.path) {
            // Preserve existing unsandboxed store at root Application Support if already created earlier.
            storeURL = legacyRootStore
        } else {
            try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
            storeURL = scopedStore
        }

        // Copy-only safety net before this build first opens the store; never overwrites/moves/deletes.
        do {
            _ = try StoreSafetyBackup.createIfNeeded(storeURL: storeURL)
        } catch {
            let nsErr = error as NSError
            NSLog("STORE_SAFETY_BACKUP_FAILED domain=%@ code=%ld", nsErr.domain, nsErr.code)
        }

        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Never delete or recreate the user's store after a migration/open failure.
            let nsErr = error as NSError
            NSLog("STORE_OPEN_FAILED domain=%@ code=%ld", nsErr.domain, nsErr.code)
            presentFatalStoreError(
                message: "无法打开便笺数据库（\(nsErr.domain) #\(nsErr.code)）。原数据已保留，请先备份数据库文件后再重试。"
            )
        }
    }()

    private static func presentFatalStoreError(message: String) -> Never {
        if Thread.isMainThread {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "Sticky Notes")
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "Done"))
            alert.runModal()
        }
        fatalError(message)
    }

    var body: some Scene {
        WindowGroup(String(localized: "Notes List")) {
            NotesListView()
                .environment(windowManager)
                .environment(activeWindowTracker)
                .onAppear { activeWindowTracker.start() }
                .background(ListWindowAccessor())
        }
        .modelContainer(Self.sharedContainer)
        .defaultSize(width: 320, height: 500)
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button(String(localized: "Cut")) {
                    NotePasteSupport.cut(in: NSApp.keyWindow)
                }
                .keyboardShortcut("x", modifiers: .command)

                Button(String(localized: "Copy")) {
                    NotePasteSupport.copy(in: NSApp.keyWindow)
                }
                .keyboardShortcut("c", modifiers: .command)

                Button(String(localized: "Paste")) {
                    NotePasteSupport.pasteIntoNote(in: NSApp.keyWindow)
                }
                .keyboardShortcut("v", modifiers: .command)

                Button(String(localized: "Select All")) {
                    NotePasteSupport.selectAll(in: NSApp.keyWindow)
                }
                .keyboardShortcut("a", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button(String(localized: "New Note")) {
                    let context = Self.sharedContainer.mainContext
                    let rawColor = UserDefaults.standard.string(forKey: "defaultColor") ?? NoteColor.yellow.rawValue
                    let color = NoteColor.fromPersisted(rawColor)
                    let scope = AuthManager.shared.activeScope
                    guard let note = StickyNote.make(in: scope, color: color) else { NSSound.beep(); return }
                    note.isOpen = true
                    context.insert(note)
                    do {
                        try context.save()
                    } catch {
                        context.delete(note)
                        NSSound.beep()
                        return
                    }
                    windowManager.markOpened(note.id)
                    openWindow(value: note.id)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu(String(localized: "Format")) {
                Button(String(localized: "Bold")) {
                    NotificationCenter.default.post(name: .formatBold, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(String(localized: "Italic")) {
                    NotificationCenter.default.post(name: .formatItalic, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button(String(localized: "Underline")) {
                    NotificationCenter.default.post(name: .formatUnderline, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)

                Button(String(localized: "Strikethrough")) {
                    NotificationCenter.default.post(name: .formatStrikethrough, object: nil)
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])

                Button(String(localized: "Bullet List")) {
                    NotificationCenter.default.post(name: .formatBulletList, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            CommandMenu(String(localized: "Sync")) {
                Button(String(localized: "Sync with Microsoft Sticky Notes")) {
                    NotificationCenter.default.post(name: .requestModelContextSync, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        WindowGroup(String(localized: "Note"), for: UUID.self) { $noteID in
            if let noteID {
                NoteWindowView(noteID: noteID)
                    .environment(windowManager)
                    .environment(activeWindowTracker)
            }
        }
        .modelContainer(Self.sharedContainer)
        .defaultSize(width: 300, height: 350)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .modelContainer(Self.sharedContainer)
        }
    }
}

extension Notification.Name {
    static let formatBold = Notification.Name("formatBold")
    static let formatItalic = Notification.Name("formatItalic")
    static let formatUnderline = Notification.Name("formatUnderline")
    static let formatStrikethrough = Notification.Name("formatStrikethrough")
    static let formatBulletList = Notification.Name("formatBulletList")
}

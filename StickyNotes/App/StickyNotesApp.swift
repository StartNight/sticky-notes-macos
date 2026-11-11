import SwiftUI
import SwiftData

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep app alive when the notes list window is closed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Always re-open the notes list when clicking the dock icon
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Always show the list window — floating note windows don't count as "the main window"
        if let window = sender.windows.first(where: Self.isNotesListWindow) {
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

    let sharedContainer: ModelContainer = {
        let schema = Schema([StickyNote.self])
        // Use the sandboxed container path so we keep existing notes data
        let containerStore = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.shenanigans.sticky-notes/Data/Library/Application Support/default.store")
        let storeURL: URL
        if FileManager.default.fileExists(atPath: containerStore.path) {
            storeURL = containerStore
        } else {
            storeURL = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        }
        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Never delete or recreate the user's store after a migration/open failure.
            fatalError("无法打开便笺数据库。原数据已保留，请备份并联系支持后重试。")
        }
    }()

    var body: some Scene {
        WindowGroup(String(localized: "Notes List")) {
            NotesListView()
                .environment(windowManager)
                .environment(activeWindowTracker)
                .onAppear { activeWindowTracker.start() }
                .background(ListWindowAccessor())
        }
        .modelContainer(sharedContainer)
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
                    let context = sharedContainer.mainContext
                    let color = NoteColor.allCases.randomElement() ?? .yellow
                    let note = StickyNote(color: color, ownerAccountID: AuthManager.shared.accountID)
                    context.insert(note)
                    try? context.save()
                    openWindow(value: note.id)
                    if AuthManager.shared.isAuthenticated {
                        SyncEngine.shared.scheduleDebouncedPush(for: note.id, in: context)
                    }
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
            }
        }
        .modelContainer(sharedContainer)
        .defaultSize(width: 300, height: 350)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .modelContainer(sharedContainer)
        }
    }
}

extension Notification.Name {
    static let formatBold = Notification.Name("formatBold")
    static let formatItalic = Notification.Name("formatItalic")
    static let formatUnderline = Notification.Name("formatUnderline")
}

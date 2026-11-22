import SwiftUI

@MainActor
@Observable
final class WindowManager {
    private(set) var openNoteIDs: Set<UUID> = []

    func markOpened(_ id: UUID) {
        openNoteIDs.insert(id)
    }

    func markClosed(_ id: UUID) {
        openNoteIDs.remove(id)
    }

    func isOpen(_ id: UUID) -> Bool {
        if !openNoteIDs.contains(id) { return false }
        if findWindow(for: id) == nil {
            // Reconcile stale openNoteIDs so a missed close callback never locks out reopening a note.
            openNoteIDs.remove(id)
            return false
        }
        return true
    }

    @discardableResult
    func bringToFront(_ id: UUID) -> Bool {
        guard let window = findWindow(for: id) else {
            openNoteIDs.remove(id)
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func closeWindow(for id: UUID) {
        findWindow(for: id)?.close()
        markClosed(id)
    }

    func windowFrame(for id: UUID) -> NSRect? {
        findWindow(for: id)?.frame
    }

    private func findWindow(for id: UUID) -> NSWindow? {
        let windows = NSApplication.shared.windows
        return windows.first { $0.identifier?.rawValue == id.uuidString && $0.isVisible }
    }
}

import AppKit

@MainActor
@Observable
final class ActiveWindowTracker {
    var isEnabled = true
    /// True while auto-following is moving windows so `NoteWindowView` does not overwrite manual positions.
    private(set) var isRepositioning = false

    private var observer: NSObjectProtocol?
    private let bundleID = Bundle.main.bundleIdentifier ?? ""

    func start() {
        // Idempotent: never overwrite/leak an existing workspace notification observer.
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }

            Task { @MainActor in
                if app.bundleIdentifier == self.bundleID {
                    self.bringNotesToFront()
                } else if self.isEnabled {
                    await self.repositionNotes(below: app)
                }
            }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private var noteWindows: [NSWindow] {
        NSApp.orderedWindows.filter {
            guard let id = $0.identifier?.rawValue, !id.isEmpty,
                  UUID(uuidString: id) != nil,
                  $0.isVisible else { return false }
            return true
        }
    }

    private func bringNotesToFront() {
        // Order back-to-front so relative Z-order among overlapping notes is preserved.
        for window in noteWindows.reversed() {
            window.orderFront(nil)
        }
    }

    private func repositionNotes(below app: NSRunningApplication) async {
        guard AXIsProcessTrusted() else { return }
        let pid = app.processIdentifier
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 900
        // Perform cross-process Accessibility IPC off MainActor with a short timeout so slow apps never freeze UI.
        let frame = await Task.detached(priority: .userInitiated) {
            Self.frontWindowFrame(for: pid, primaryScreenHeight: primaryScreenHeight)
        }.value
        guard let frame else { return }

        let windows = noteWindows
        guard !windows.isEmpty else { return }

        let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.screens.first
            ?? NSScreen.main
        let screen = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 8
        let targetTop = frame.origin.y - gap

        var xCursor = frame.origin.x
        isRepositioning = true
        defer { isRepositioning = false }

        for window in windows {
            let noteSize = window.frame.size
            let newY = targetTop - noteSize.height

            if xCursor + noteSize.width > frame.origin.x + frame.width + gap && xCursor != frame.origin.x {
                xCursor = frame.origin.x
            }

            let maxX = max(screen.minX, screen.maxX - noteSize.width)
            let maxY = max(screen.minY, screen.maxY - noteSize.height)
            let clampedX = min(max(xCursor, screen.minX), maxX)
            let clampedY = min(max(newY, screen.minY), maxY)

            window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))

            xCursor += noteSize.width + gap
        }
    }

    nonisolated private static func frontWindowFrame(for pid: pid_t, primaryScreenHeight: CGFloat) -> NSRect? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.15)

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let rawWindow = windowRef,
           CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
            let axWindow = rawWindow as! AXUIElement
            return frameOf(axWindow, primaryScreenHeight: primaryScreenHeight)
        }

        var windowListRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowListRef) == .success,
              let windows = windowListRef as? [AXUIElement],
              let first = windows.first else {
            return nil
        }
        return frameOf(first, primaryScreenHeight: primaryScreenHeight)
    }

    nonisolated private static func frameOf(_ axWindow: AXUIElement, primaryScreenHeight: CGFloat) -> NSRect? {
        AXUIElementSetMessagingTimeout(axWindow, 0.15)
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let rawPos = posRef,
              let rawSize = sizeRef,
              CFGetTypeID(rawPos) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }

        let posValue = rawPos as! AXValue
        let sizeValue = rawSize as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        let appKitY = primaryScreenHeight - position.y - size.height

        return NSRect(x: position.x, y: appKitY, width: size.width, height: size.height)
    }
}

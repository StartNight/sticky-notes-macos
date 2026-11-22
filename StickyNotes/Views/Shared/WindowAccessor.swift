import SwiftUI

/// Lightweight host view that notifies deterministically when attached to an `NSWindow`
/// (eliminating missed single-shot `DispatchQueue.main.async` window races).
private final class WindowObservingNSView: NSView {
    var onAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onAttach?(window)
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let noteID: UUID?
    let noteColor: NoteColor
    let onWindowFound: ((NSWindow) -> Void)?
    let onClose: (() -> Void)?
    let windowFrame: NSRect?
    let onFrameChanged: ((NSRect) -> Void)?

    init(
        noteID: UUID? = nil,
        noteColor: NoteColor = .yellow,
        windowFrame: NSRect? = nil,
        onWindowFound: ((NSWindow) -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onFrameChanged: ((NSRect) -> Void)? = nil
    ) {
        self.noteID = noteID
        self.noteColor = noteColor
        self.windowFrame = windowFrame
        self.onWindowFound = onWindowFound
        self.onClose = onClose
        self.onFrameChanged = onFrameChanged
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingNSView()
        view.onAttach = { [weak coordinator = context.coordinator] window in
            coordinator?.configureWindowIfNeeded(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        if let window = nsView.window {
            context.coordinator.configureWindowIfNeeded(window)
            context.coordinator.updateWindowAppearance(window, color: noteColor)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        (nsView as? WindowObservingNSView)?.onAttach = nil
        coordinator.teardownObservers()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: WindowAccessor
        private weak var configuredWindow: NSWindow?
        private var observerTokens: [NSObjectProtocol] = []

        init(_ parent: WindowAccessor) {
            self.parent = parent
        }

        deinit {
            teardownObservers()
        }

        func teardownObservers() {
            for token in observerTokens {
                NotificationCenter.default.removeObserver(token)
            }
            observerTokens.removeAll()
        }

        func configureWindowIfNeeded(_ window: NSWindow) {
            guard configuredWindow !== window else { return }
            teardownObservers()
            configuredWindow = window

            // Do NOT overwrite `window.delegate` (SwiftUI relies on its own AppKitWindowDelegate).
            // Use scoped NotificationCenter observers instead.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 200, height: 150)
            updateWindowAppearance(window, color: parent.noteColor)

            if let noteID = parent.noteID {
                window.identifier = NSUserInterfaceItemIdentifier(noteID.uuidString)
                window.title = String(localized: "Note")
                window.isExcludedFromWindowsMenu = true
                window.styleMask.remove(.miniaturizable)
                window.collectionBehavior.insert([.fullScreenAuxiliary, .ignoresCycle])
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            }

            if let frame = parent.windowFrame {
                window.setFrame(frame, display: true)
            }

            window.level = parent.noteID == nil ? .normal : .floating

            let center = NotificationCenter.default
            observerTokens.append(
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    self?.parent.onClose?()
                }
            )
            observerTokens.append(
                center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] note in
                    if let w = note.object as? NSWindow {
                        self?.parent.onFrameChanged?(w.frame)
                    }
                }
            )
            observerTokens.append(
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] note in
                    if let w = note.object as? NSWindow {
                        self?.parent.onFrameChanged?(w.frame)
                    }
                }
            )

            parent.onWindowFound?(window)
        }

        func updateWindowAppearance(_ window: NSWindow, color: NoteColor) {
            let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bgColor = isDark ? color.darkBackground : color.background
            window.backgroundColor = NSColor(bgColor)
        }
    }
}

/// Identifies the notes-list window for dock-reopen and UI automation.
struct ListWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingNSView()
        view.onAttach = { Self.apply(to: $0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.apply(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? WindowObservingNSView)?.onAttach = nil
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("notes-list")
        window.title = String(localized: "Notes List")
    }
}

/// Closes its host window once (used when a note window's note is outside the active account scope).
/// Cancels safely if dismantled before closing so a quick scope bounce never closes a valid window.
struct ScopeWindowCloser: NSViewRepresentable {
    let onClose: () -> Void

    final class Coordinator {
        var cancelled = false
        var didClose = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingNSView()
        let coordinator = context.coordinator
        view.onAttach = { window in
            DispatchQueue.main.async {
                guard !coordinator.cancelled, !coordinator.didClose else { return }
                coordinator.didClose = true
                onClose()
                window.close()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window, !context.coordinator.cancelled, !context.coordinator.didClose {
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                guard !coordinator.cancelled, !coordinator.didClose else { return }
                coordinator.didClose = true
                onClose()
                window.close()
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.cancelled = true
        (nsView as? WindowObservingNSView)?.onAttach = nil
    }
}

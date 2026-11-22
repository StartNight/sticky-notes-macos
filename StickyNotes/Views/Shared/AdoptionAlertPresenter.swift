import AppKit

/// App-level (window-independent) dialog for the first-sign-in question about no-account notes.
/// Three explicit outcomes; Esc and closing the dialog are "Not Now" (skip this time), never a remembered refusal.
/// Never steals focus from another app and never binds Return ("\r") to cloud upload.
@MainActor
final class AppKitAdoptionPromptPresenter: AdoptionPromptPresenting {
    func present(_ info: AdoptionPromptInfo) async -> AdoptionChoice {
        // Wait until the app is frontmost and no modal sheet/panel is open so we never steal focus
        // from another app or intercept a stray Return keystroke.
        await waitUntilSafeToPresent()
        if Task.isCancelled { return .skip }

        let alert = NSAlert()
        alert.alertStyle = .informational
        let who = info.accountLabel
        alert.messageText = String(localized: "Sync no-account notes to \(who)?")
        let count = String(info.count)
        let baseTitles = info.titles.joined(separator: ", ")
        let titles = info.count > info.titles.count ? "\(baseTitles)…" : baseTitles
        alert.informativeText = String(localized: "\(count) note(s) were created while signed out: \(titles). Nothing is merged or uploaded until you confirm. “Keep as No-Account Notes” stops asking about these notes; “Not Now” (or Esc) only skips this time and asks again next time.")
        let accept = alert.addButton(withTitle: String(localized: "Sync to This Account"))
        accept.keyEquivalent = "" // Explicit click required; never bind Return to cloud upload.
        let decline = alert.addButton(withTitle: String(localized: "Keep as No-Account Notes"))
        decline.keyEquivalent = ""
        let skip = alert.addButton(withTitle: String(localized: "Not Now"))
        skip.keyEquivalent = "\u{1b}"   // Esc == Not Now (never the remembered refusal)

        if let hostWindow = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.level == .normal }) {
            let response = await alert.beginSheetModal(for: hostWindow)
            return Self.choice(for: response)
        }
        return Self.choice(for: alert.runModal())
    }

    private static func choice(for response: NSApplication.ModalResponse) -> AdoptionChoice {
        switch response {
        case .alertFirstButtonReturn: return .accept
        case .alertSecondButtonReturn: return .decline
        default: return .skip
        }
    }

    private func waitUntilSafeToPresent() async {
        while !Task.isCancelled && (!NSApp.isActive || NSApp.modalWindow != nil) {
            if !NSApp.isActive {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    var token: NSObjectProtocol?
                    token = NotificationCenter.default.addObserver(
                        forName: NSApplication.didBecomeActiveNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        if let t = token {
                            NotificationCenter.default.removeObserver(t)
                            token = nil
                        }
                        continuation.resume()
                    }
                }
            } else {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}

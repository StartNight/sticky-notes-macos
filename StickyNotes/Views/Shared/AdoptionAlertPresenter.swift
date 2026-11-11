import AppKit

/// App-level (window-independent) dialog for the first-sign-in question about no-account notes.
/// Three explicit outcomes; Esc and closing the dialog are "Not Now" (skip this time), never a remembered refusal.
@MainActor
final class AppKitAdoptionPromptPresenter: AdoptionPromptPresenting {
    func present(_ info: AdoptionPromptInfo) async -> AdoptionChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let who = info.accountLabel
        alert.messageText = String(localized: "Sync no-account notes to \(who)?")
        let count = String(info.count)
        let titles = info.titles.joined(separator: ", ")
        alert.informativeText = String(localized: "\(count) note(s) were created while signed out: \(titles). Nothing is merged or uploaded until you confirm. “Keep as No-Account Notes” stops asking about these notes; “Not Now” (or Esc) only skips this time and asks again next time.")
        let accept = alert.addButton(withTitle: String(localized: "Sync to This Account"))
        accept.keyEquivalent = "\r"
        let decline = alert.addButton(withTitle: String(localized: "Keep as No-Account Notes"))
        decline.keyEquivalent = ""
        let skip = alert.addButton(withTitle: String(localized: "Not Now"))
        skip.keyEquivalent = "\u{1b}"   // Esc == Not Now (never the remembered refusal)
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .accept
        case .alertSecondButtonReturn: return .decline
        default: return .skip
        }
    }
}

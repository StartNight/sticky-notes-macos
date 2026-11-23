import AppKit

/// Explicit URL scheme allowlist for opening links from untrusted note content.
enum SafeURLPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            return false
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return false }
        }
        return true
    }

    static func validatedURL(from link: Any) -> URL? {
        let candidate: URL?
        if let url = link as? URL {
            candidate = url
        } else if let str = link as? String {
            candidate = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            candidate = nil
        }
        guard let url = candidate, isAllowed(url) else { return nil }
        return url
    }
}

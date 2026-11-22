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

struct URLDetector {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func detectAndApplyLinks(in attributedString: NSMutableAttributedString) {
        guard let detector = linkDetector else { return }
        let text = attributedString.string
        let fullRange = NSRange(location: 0, length: attributedString.length)
        let matches = detector.matches(in: text, options: [], range: fullRange)

        attributedString.beginEditing()
        defer { attributedString.endEditing() }
        for match in matches {
            guard let url = match.url, SafeURLPolicy.isAllowed(url) else { continue }
            attributedString.addAttribute(.link, value: url, range: match.range)
            attributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            attributedString.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range)
        }
    }
}

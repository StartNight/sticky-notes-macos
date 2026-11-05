import AppKit
import Foundation

struct NoteConverter {
    // MARK: - HTML to NSAttributedString

    static func htmlToAttributedString(_ html: String) -> NSAttributedString {
        guard !html.isEmpty else {
            return NSAttributedString(string: "", attributes: defaultAttributes)
        }

        // Clean up common Windows/Outlook HTML artifacts if present
        let preprocessedHtml = preprocessHtml(html)

        guard let data = preprocessedHtml.data(using: .utf8) else {
            return NSAttributedString(string: html, attributes: defaultAttributes)
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let parsed = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else {
            // Fallback to plain text if HTML parsing fails
            return NSAttributedString(string: extractPlainText(from: html), attributes: defaultAttributes)
        }

        // Normalize fonts to System Font 14 while preserving bold and italic traits
        normalizeFonts(in: parsed)

        // Ensure text color is appropriate for current theme
        normalizeColors(in: parsed)

        // AppKit's HTML importer appends a trailing newline for block-level tags
        // such as </div>. Strip extras so repeated round-trips stay a fixed point.
        trimTrailingHTMLNewlines(in: parsed)

        return parsed
    }

    // MARK: - NSAttributedString to HTML

    static func attributedStringToHtml(_ attrStr: NSAttributedString) -> String {
        guard attrStr.length > 0 else { return "<div></div>" }

        var html = "<div>"
        let string = attrStr.string as NSString
        let fullRange = NSRange(location: 0, length: attrStr.length)

        attrStr.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let substring = string.substring(with: range)
            var formatted = escapeHtml(substring)

            // Replace line breaks with <br/>
            formatted = formatted.replacingOccurrences(of: "\n", with: "<br/>")

            // Font traits (Bold / Italic)
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.italic) {
                    formatted = "<i>\(formatted)</i>"
                }
                if traits.contains(.bold) {
                    formatted = "<b>\(formatted)</b>"
                }
            }

            // Underline
            if let underline = attrs[.underlineStyle] as? Int, underline != 0 {
                formatted = "<u>\(formatted)</u>"
            }

            // Strikethrough
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 {
                formatted = "<s>\(formatted)</s>"
            }

            // Foreground Color
            if let color = attrs[.foregroundColor] as? NSColor {
                if let hex = colorToHex(color) {
                    formatted = "<span style=\"color:\(hex);\">\(formatted)</span>"
                }
            }

            html.append(formatted)
        }

        html.append("</div>")
        return html
    }

    // MARK: - Plain Text Conversion

    static func plainTextToHtml(_ plainText: String) -> String {
        let escaped = escapeHtml(plainText)
        let withBreaks = escaped.replacingOccurrences(of: "\n", with: "<br/>")
        return "<div>\(withBreaks)</div>"
    }

    static func extractPlainText(from html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "</li>", with: "\n")

        // Strip HTML tags using regex
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: text.utf16.count),
                withTemplate: ""
            )
        }

        // Unescape HTML entities
        text = unescapeHtml(text)

        // Trim excessive empty lines
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Color Mapping for Microsoft Sticky Notes (PidLidNoteColor)
    // 0 = Blue, 1 = Green, 2 = Pink, 3 = Yellow, 4 = White/Gray

    static func outlookColorCode(for noteColor: NoteColor) -> Int {
        switch noteColor {
        case .blue: return 0
        case .green: return 1
        case .pink: return 2
        case .yellow: return 3
        case .gray: return 4
        // Outlook PidLidNoteColor only documents 0-4. Use 5/6 so every local
        // color has a stable, reversible code (purple/orange would otherwise
        // collapse to pink/yellow).
        case .purple: return 5
        case .orange: return 6
        }
    }

    static func noteColor(fromOutlookCode code: Int) -> NoteColor {
        switch code {
        case 0: return .blue
        case 1: return .green
        case 2: return .pink
        case 3: return .yellow
        case 4: return .gray
        case 5: return .purple
        case 6: return .orange
        default: return .yellow
        }
    }

    // MARK: - Internal Helpers

    private static var defaultAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor
        ]
    }

    private static func preprocessHtml(_ html: String) -> String {
        var result = html
        // Wrap with UTF-8 meta to avoid encoding misdetections
        if !result.contains("<meta charset") && !result.contains("<meta http-equiv=\"Content-Type\"") {
            result = "<html><head><meta charset=\"utf-8\"></head><body>\(result)</body></html>"
        }
        return result
    }

    private static func normalizeFonts(in attrStr: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attrStr.length)
        attrStr.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let isBold: Bool
            let isItalic: Bool
            if let font = value as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                isBold = traits.contains(.bold)
                isItalic = traits.contains(.italic)
            } else {
                isBold = false
                isItalic = false
            }

            var font = NSFont.systemFont(ofSize: 14)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if isBold { traits.insert(.bold) }
            if isItalic { traits.insert(.italic) }

            if !traits.isEmpty {
                let desc = font.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: desc, size: 14) ?? font
            }

            attrStr.removeAttribute(.font, range: range)
            attrStr.addAttribute(.font, value: font, range: range)
        }
    }

    private static func normalizeColors(in attrStr: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attrStr.length)
        attrStr.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else {
                attrStr.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                return
            }
            // If the text color is black in dark mode or pure white in light mode, use dynamic textColor
            if color == NSColor.black || color == NSColor.white {
                attrStr.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            }
        }
    }

    private static func colorToHex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        // Don't encode standard default text colors into HTML
        if color == NSColor.textColor || color == NSColor.labelColor {
            return nil
        }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func escapeHtml(_ string: String) -> String {
        var escaped = string
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        return escaped
    }

    private static func unescapeHtml(_ string: String) -> String {
        var unescaped = decodeNumericHtmlEntities(string)
        unescaped = unescaped.replacingOccurrences(of: "&quot;", with: "\"")
        unescaped = unescaped.replacingOccurrences(of: "&apos;", with: "'")
        unescaped = unescaped.replacingOccurrences(of: "&gt;", with: ">")
        unescaped = unescaped.replacingOccurrences(of: "&lt;", with: "<")
        unescaped = unescaped.replacingOccurrences(of: "&nbsp;", with: " ")
        unescaped = unescaped.replacingOccurrences(of: "&amp;", with: "&")
        return unescaped
    }

    /// Decode &#NNN; and &#xHH; numeric entities. NBSP (160) becomes a regular
    /// space to match `&nbsp;` handling used by titles/previews.
    private static func decodeNumericHtmlEntities(_ string: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);", options: .caseInsensitive) else {
            return string
        }
        let nsString = string as NSString
        let matches = regex.matches(in: string, options: [], range: NSRange(location: 0, length: nsString.length))
        var result = string
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range, in: result),
                  let codeRange = Range(match.range(at: 1), in: result) else { continue }
            let code = String(result[codeRange])
            let value: UInt32?
            if code.lowercased().hasPrefix("x") {
                value = UInt32(code.dropFirst(), radix: 16)
            } else {
                value = UInt32(code)
            }
            guard let scalarValue = value else { continue }
            let replacement: String
            if scalarValue == 160 {
                replacement = " "
            } else if let scalar = Unicode.Scalar(scalarValue) {
                replacement = String(Character(scalar))
            } else {
                continue
            }
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private static func trimTrailingHTMLNewlines(in attrStr: NSMutableAttributedString) {
        while attrStr.length > 0 {
            let last = (attrStr.string as NSString).substring(from: attrStr.length - 1)
            if last == "\n" {
                attrStr.deleteCharacters(in: NSRange(location: attrStr.length - 1, length: 1))
            } else {
                break
            }
        }
    }
}

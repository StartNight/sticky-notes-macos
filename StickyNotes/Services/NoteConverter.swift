import AppKit
import Foundation
import CryptoKit
import os

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

    // MARK: - Color Mapping for official Microsoft Sticky Notes
    //
    // Two independent encodings are written on every upload:
    //
    // 1) Modern web / Windows Sticky Notes (`_Note.color`), picker order:
    //    0=Yellow, 1=Green, 2=Pink, 3=Purple, 4=Blue, 5=Gray, 6=Charcoal
    //    Outlook on the web and onenote.com/stickynotes read this field
    //    (not PidLidNoteColor). See https://stackoverflow.com/questions/67943130
    //
    // 2) Classic Outlook desktop PidLidNoteColor (MS-OXONOTE 0x8B00):
    //    0=Blue, 1=Green, 2=Pink, 3=Yellow, 4=White
    //    Purple and Charcoal have no documented classic value; they fall
    //    back to White (4) so desktop Outlook does not show a wrong hue.
    //
    // Earlier builds wrote the same integer to both fields (yellow→0). That
    // made 0x8B00 report Blue while `_Note` reported Yellow, so web/desktop
    // clients that reconcile via 0x8B00 (or notes that never received `_Note`)
    // displayed a different color than this app. Always write the two
    // encodings separately, and prefer `_Note` when reading.

    /// Modern web Sticky Notes color (`_Note.color`).
    static func webNoteColorCode(for noteColor: NoteColor) -> Int {
        switch noteColor {
        case .yellow: return 0
        case .green: return 1
        case .pink: return 2
        case .purple: return 3
        case .blue: return 4
        case .gray: return 5
        case .charcoal: return 6
        }
    }

    static func noteColor(fromWebCode code: Int) -> NoteColor {
        switch code {
        case 0: return .yellow
        case 1: return .green
        case 2: return .pink
        case 3: return .purple
        case 4: return .blue
        case 5: return .gray
        case 6: return .charcoal
        default: return .yellow
        }
    }

    /// Classic Outlook desktop PidLidNoteColor (MS-OXONOTE).
    static func pidLidNoteColorCode(for noteColor: NoteColor) -> Int {
        switch noteColor {
        case .blue: return 0
        case .green: return 1
        case .pink: return 2
        case .yellow: return 3
        case .gray, .purple, .charcoal: return 4
        }
    }

    static func noteColor(fromPidLidCode code: Int) -> NoteColor {
        switch code {
        case 0: return .blue
        case 1: return .green
        case 2: return .pink
        case 3: return .yellow
        case 4: return .gray
        case 5: return .gray
        case 6: return .charcoal
        default: return .yellow
        }
    }

    /// Back-compat alias used by tests and older call sites: web/modern code.
    static func outlookColorCode(for noteColor: NoteColor) -> Int {
        webNoteColorCode(for: noteColor)
    }

    static func noteColor(fromOutlookCode code: Int) -> NoteColor {
        noteColor(fromWebCode: code)
    }

    /// Classic Outlook desktop color (MS-OXONOTE PidLidNoteColor). Web Sticky Notes
    /// ignore this and read `color` inside the `_Note` JSON blob instead
    /// (see https://stackoverflow.com/questions/67943130).
    static let pidLidNoteColorPropertyId = "Integer {0006200e-0000-0000-c000-000000000046} Id 0x8b00"

    /// PS_PUBLIC_STRINGS named property used by OWA / Outlook on the web.
    static let webNoteJSONPropertyId = "String {00020329-0000-0000-c000-000000000046} Name _Note"

    static func isPidLidNoteColorProperty(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("0x8b00") || lower.contains("0x35e0")
    }

    static func isWebNoteJSONProperty(_ id: String) -> Bool {
        let lower = id.lowercased().replacingOccurrences(of: "  ", with: " ")
        return lower.contains("name _note")
    }

    static func noteColor(fromWebNoteJSON json: String) -> NoteColor? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let code: Int?
        if let value = obj["color"] as? Int {
            code = value
        } else if let value = obj["color"] as? NSNumber {
            code = value.intValue
        } else if let value = obj["color"] as? String {
            code = Int(value)
        } else {
            code = nil
        }
        guard let code else { return nil }
        return noteColor(fromOutlookCode: code)
    }

    /// Merge `color` into an existing modern `_Note` JSON document so we do not
    /// wipe OWA's canvas/document payload when only the color changed.
    static func webNoteJSON(setting color: NoteColor, existing: String?) -> String {
        var obj: [String: Any] = [:]
        if let existing, let data = existing.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        if obj["schemaVersion"] == nil {
            obj["schemaVersion"] = "beta"
        }
        obj["color"] = outlookColorCode(for: color)
        obj["#type.color"] = "Int32"
        obj["color@Is.Queryable"] = "True"
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"color\":\(outlookColorCode(for: color)),\"#type.color\":\"Int32\"}"
        }
        return text
    }

    static func graphColorExtendedProperties(for color: NoteColor, existingWebNoteJSON: String?) -> [[String: Any]] {
        [
            [
                "id": pidLidNoteColorPropertyId,
                "value": "\(pidLidNoteColorCode(for: color))"
            ],
            [
                "id": webNoteJSONPropertyId,
                "value": webNoteJSON(setting: color, existing: existingWebNoteJSON)
            ]
        ]
    }

    static func extractNoteColor(fromExtendedProperties props: [[String: Any]]) -> (color: NoteColor, webNoteJSON: String?) {
        var lidColor: NoteColor?
        var webColor: NoteColor?
        var webJSON: String?
        for prop in props {
            guard let propId = prop["id"] as? String else { continue }
            if isWebNoteJSONProperty(propId), let value = prop["value"] as? String {
                webJSON = value
                webColor = noteColor(fromWebNoteJSON: value)
            } else if isPidLidNoteColorProperty(propId),
                      let value = prop["value"] as? String,
                      let code = Int(value) {
                lidColor = noteColor(fromPidLidCode: code)
            }
        }
        return (webColor ?? lidColor ?? .yellow, webJSON)
    }

    /// 仅用于诊断：颜色判定所依据的原始线上值（不改变行为）。
    /// `source` 表示由哪个字段决定颜色："_Note" | "0x8B00" | "default(yellow)"。
    static func rawColorCodes(fromExtendedProperties props: [[String: Any]]) -> (webCode: Int?, lidCode: Int?, source: String) {
        var web: Int?
        var lid: Int?
        for prop in props {
            guard let propId = prop["id"] as? String, let value = prop["value"] as? String else { continue }
            if isWebNoteJSONProperty(propId) {
                if let data = value.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let v = obj["color"] as? Int { web = v }
                    else if let v = obj["color"] as? NSNumber { web = v.intValue }
                    else if let v = obj["color"] as? String { web = Int(v) }
                }
            } else if isPidLidNoteColorProperty(propId) {
                lid = Int(value)
            }
        }
        let source = web != nil ? "_Note" : (lid != nil ? "0x8B00" : "default(yellow)")
        return (web, lid, source)
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


/// 可选的颜色同步诊断（统一日志，不记录正文、标题或 token）。
/// 开启：defaults write com.shenanigans.sticky-notes ColorDiagnosticsEnabled -bool YES
/// （每次调用时读取，无需重启；App 自己从不写这个键）
/// 查看：log show --last 10m --info --predicate 'subsystem == "com.shenanigans.sticky-notes" AND category == "color-sync"'
enum ColorDiagnostics {
    private static let logger = Logger(subsystem: "com.shenanigans.sticky-notes", category: "color-sync")
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "ColorDiagnosticsEnabled") }

    /// Graph 对象 id 的短且不可逆标签（SHA-256 前 6 位十六进制），用于在拉取/上传日志行之间对应同一条便笺，且不暴露原始 id。
    static func tag(_ id: String?) -> String {
        guard let id else { return "-" }
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }
    private static func code(_ v: Int?) -> String { v.map(String.init) ?? "-" }

    /// 拉取到的每条云端便笺一行。`local` 是本次拉取改动之前的本地颜色（"-" 表示新建）。
    static func pull(event: String, remoteID: String, local: NoteColor?, props: [[String: Any]], resolved: NoteColor) {
        guard enabled else { return }
        let raw = NoteConverter.rawColorCodes(fromExtendedProperties: props)
        logger.notice("pull event=\(event, privacy: .public) id=\(tag(remoteID), privacy: .public) local=\(local?.rawValue ?? "-", privacy: .public) down_Note=\(code(raw.webCode), privacy: .public) down_0x8B00=\(code(raw.lidCode), privacy: .public) resolved=\(resolved.rawValue, privacy: .public) source=\(raw.source, privacy: .public) propsReturned=\(props.count, privacy: .public)")
    }

    /// 每次上传一行，记录实际发出去的颜色。
    /// `sent` = "local"（用户改过色 / 全新便笺）| "none"（未带颜色属性）|
    /// "cached_Note"（原样搬运缓存的云端 `_Note`）| "server_copy"（原样搬运刚读到的服务端原始属性）。
    /// `up_*` 仅在 `sent=local` 时有意义。
    static func upload(event: String, remoteID: String?, local: NoteColor, sent: String) {
        guard enabled else { return }
        let note = sent == "local" ? String(NoteConverter.webNoteColorCode(for: local)) : "-"
        let lid = sent == "local" ? String(NoteConverter.pidLidNoteColorCode(for: local)) : "-"
        logger.notice("upload event=\(event, privacy: .public) id=\(tag(remoteID), privacy: .public) local=\(local.rawValue, privacy: .public) sent=\(sent, privacy: .public) up_Note=\(note, privacy: .public) up_0x8B00=\(lid, privacy: .public)")
    }

    /// 网页原色保护的每次判定一行。`path` = patch | create | replace | conflict-copy | pull-cloud-wins。
    /// `policy` = writeLocal | omit | carryCached | carryServer；`detail` 是固定短标记（绝不含便笺正文）。
    static func guardDecision(path: String, remoteID: String?, dirty: Bool, policy: String, detail: String = "-") {
        guard enabled else { return }
        logger.notice("guard path=\(path, privacy: .public) id=\(tag(remoteID), privacy: .public) dirty=\(dirty, privacy: .public) policy=\(policy, privacy: .public) detail=\(detail, privacy: .public)")
    }
}

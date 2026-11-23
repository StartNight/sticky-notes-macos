import AppKit
import Foundation
import CryptoKit
import os

struct NoteConverter {
    // MARK: - HTML to NSAttributedString (Offline Safe Parser)

    /// Parses cloud/Outlook HTML completely offline without WebKit, external subresource loading,
    /// `file://` access, or main-thread `RunLoop` pumping.
    static func htmlToAttributedString(_ html: String) -> NSAttributedString {
        guard !html.isEmpty else {
            return NSAttributedString(string: "", attributes: defaultAttributes)
        }
        return OfflineHTMLParser.parse(html)
    }

    // MARK: - NSAttributedString to HTML

    private static let hiddenTextKey = NSAttributedString.Key("com.stickynotes.hiddenText")
    private static let maxExportedImageBytes = 2 * 1024 * 1024

    static func attributedStringToHtml(_ attrStr: NSAttributedString) -> String {
        guard attrStr.length > 0 else { return "<div></div>" }

        var html = "<div>"
        let string = attrStr.string as NSString
        let fullRange = NSRange(location: 0, length: attrStr.length)

        attrStr.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let imgTag = inlineImageTag(for: attachment) {
                    html.append(imgTag)
                }
                return
            }

            let rawSubstring = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !rawSubstring.isEmpty else { return }

            var formatted = escapeHtml(rawSubstring)

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

            // Hidden/spoiler text marker (preserved across Mac round-trips and visually masked on web)
            let isHidden = (attrs[hiddenTextKey] as? Bool) == true
            if isHidden {
                formatted = "<span data-stickynotes-hidden=\"1\" style=\"background-color:#262626;color:#262626;\">\(formatted)</span>"
            } else if let color = attrs[.foregroundColor] as? NSColor,
                      let hex = colorToHex(color) {
                formatted = "<span style=\"color:\(hex);\">\(formatted)</span>"
            }

            // Safe link preservation
            if !isHidden, let linkVal = attrs[.link], let safeURL = SafeURLPolicy.validatedURL(from: linkVal) {
                let escapedHref = escapeHtml(safeURL.absoluteString)
                formatted = "<a href=\"\(escapedHref)\">\(formatted)</a>"
            }

            html.append(formatted)
        }

        html.append("</div>")
        return html
    }

    private static func inlineImageTag(for attachment: NSTextAttachment) -> String? {
        let image: NSImage?
        if let direct = attachment.image {
            image = direct
        } else if let data = attachment.fileWrapper?.regularFileContents {
            image = NSImage(data: data)
        } else {
            image = nil
        }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        let pngData = rep.representation(using: .png, properties: [:])
        guard let data = pngData, data.count <= maxExportedImageBytes else {
            return nil
        }
        return "<img src=\"data:image/png;base64,\(data.base64EncodedString())\"/>"
    }

    // MARK: - Plain Text Conversion

    static func plainTextToHtml(_ plainText: String) -> String {
        let escaped = escapeHtml(plainText)
        let withBreaks = escaped.replacingOccurrences(of: "\n", with: "<br/>")
        return "<div>\(withBreaks)</div>"
    }

    static func extractPlainText(from html: String) -> String {
        guard !html.isEmpty else { return "" }
        let raw = OfflineHTMLParser.parse(html).string.replacingOccurrences(of: "\u{FFFC}", with: "")
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
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

    /// MAPI IconIndex (MS-OXOMSG 2.2.1.10 / MS-OXONOTE 2.2.1.2 PidTagIconIndex 0x10800003).
    /// Used by Outlook folder views and list controls to display colored note icons.
    static let pidTagIconIndexPropertyId = "Integer 0x1080"

    /// PS_PUBLIC_STRINGS named property used by OWA / Outlook on the web.
    static let webNoteJSONPropertyId = "String {00020329-0000-0000-c000-000000000046} Name _Note"

    static func isPidLidNoteColorProperty(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("0x8b00") || lower.contains("0x35e0")
    }

    static func isPidTagIconIndexProperty(_ id: String) -> Bool {
        id.lowercased().contains("0x1080")
    }

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func isWebNoteJSONProperty(_ id: String) -> Bool {
        let collapsed = id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.hasSuffix("name _note")
    }

    /// Icon index corresponding to note color (MS-OXONOTE 2.2.1.2: 0x300 + PidLidNoteColor).
    static func pidTagIconIndex(for color: NoteColor) -> Int {
        0x300 + pidLidNoteColorCode(for: color)
    }

    static func noteColor(fromPidTagIconIndex index: Int) -> NoteColor {
        switch index {
        case 0x300: return .blue
        case 0x301: return .green
        case 0x302: return .pink
        case 0x303: return .yellow
        case 0x304: return .gray
        default: return .yellow
        }
    }

    /// Whether the JSON payload is a modern web note missing the required Substrate document structure.
    static func isIncompleteWebNoteJSON(_ json: String?) -> Bool {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return obj["document"] == nil
    }

    /// Identifies notes generated by legacy versions of this Mac client that lacked the Substrate document structure.
    static func isLegacyMacAuthoredIncompleteNoteJSON(_ json: String?) -> Bool {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let hasBetaSchema = (obj["schemaVersion"] as? String) == "beta"
        let hasTypeColor = (obj["#type.color"] as? String) == "Int32"
        let hasColorQueryable = (obj["color@Is.Queryable"] as? String) == "True"
        let missingDocument = (obj["document"] == nil)
        return hasBetaSchema && hasTypeColor && hasColorQueryable && missingDocument
    }

    /// Whether the JSON payload is a complete Substrate document with block content.
    static func hasCompleteSubstrateDocument(_ json: String?) -> Bool {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let doc = obj["document"] as? [String: Any],
              let blocks = doc["blocks"] as? [[String: Any]],
              !blocks.isEmpty else {
            return false
        }
        return true
    }

    private static func isJSONBoolean(_ value: Any?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func noteColor(fromWebNoteJSON json: String) -> NoteColor? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let code: Int?
        let rawColor = obj["color"]
        if isJSONBoolean(rawColor) {
            code = nil
        } else if let value = rawColor as? Int {
            code = value
        } else if let value = rawColor as? NSNumber {
            code = value.intValue
        } else if let value = rawColor as? String {
            code = Int(value)
        } else {
            code = nil
        }
        guard let code else { return nil }
        return noteColor(fromOutlookCode: code)
    }

    /// Merge `color` into an existing modern `_Note` JSON document so we do not
    /// wipe OWA's canvas/document payload when only the color changed. When no OWA
    /// `document` exists yet (e.g. notes created on macOS), populate a valid
    /// Substrate `_Note` block document so Outlook on the web renders the color
    /// instead of falling back to gray.
    static func webNoteJSON(
        setting color: NoteColor,
        existing: String?,
        plainText: String? = nil,
        localID: UUID? = nil,
        modifiedAt: Date = Date()
    ) -> String {
        var obj: [String: Any] = [:]
        if let existing, let data = existing.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        if obj["schemaVersion"] == nil {
            obj["schemaVersion"] = "beta"
        }

        let createdByStickyNotes = (obj["createdByApp"] as? String) == "StickyNotes"
        let matchesThisLocalNote = localID != nil && (obj["createdWithLocalId"] as? String)?.lowercased() == localID?.uuidString.lowercased()
        let isMacAuthoredDocument = createdByStickyNotes && (matchesThisLocalNote || obj["document"] == nil)
        if obj["document"] == nil || (plainText != nil && isMacAuthoredDocument) {
            obj["document"] = substrateDocument(for: plainText ?? "")
            obj["documentModifiedAt"] = isoFormatterFractional.string(from: modifiedAt)
        } else if obj["documentModifiedAt"] == nil {
            obj["documentModifiedAt"] = isoFormatterFractional.string(from: modifiedAt)
        }
        if obj["documentModifiedAt@Is.Queryable"] == nil { obj["documentModifiedAt@Is.Queryable"] = "True" }
        if obj["#type.documentModifiedAt"] == nil { obj["#type.documentModifiedAt"] = "DateTime" }

        if obj["createdWithLocalId"] == nil {
            obj["createdWithLocalId"] = (localID ?? UUID()).uuidString.lowercased()
        }
        if obj["createdWithLocalId@Is.Queryable"] == nil { obj["createdWithLocalId@Is.Queryable"] = "True" }
        if obj["#type.createdWithLocalId"] == nil { obj["#type.createdWithLocalId"] = "String" }

        if obj["createdByApp"] == nil {
            obj["createdByApp"] = "StickyNotes"
        }
        if obj["createdByApp@Is.Queryable"] == nil { obj["createdByApp@Is.Queryable"] = "True" }
        if obj["#type.createdByApp"] == nil { obj["#type.createdByApp"] = "String" }

        obj["color"] = outlookColorCode(for: color)
        obj["#type.color"] = "Int32"
        obj["color@Is.Queryable"] = "True"
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"color\":\(outlookColorCode(for: color)),\"#type.color\":\"Int32\"}"
        }
        return text
    }

    private static func substrateDocument(for plainText: String) -> [String: Any] {
        let normalized = plainText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let blocks: [[String: Any]] = (lines.isEmpty ? [""] : lines).map { line in
            [
                "type": "paragraph",
                "id": UUID().uuidString.lowercased(),
                "blockStyles": ["textDirection": "ltr"],
                "content": [["text": line, "styles": [String]()]]
            ]
        }
        return [
            "type": "document",
            "blocks": blocks
        ]
    }

    static func graphColorExtendedProperties(
        for color: NoteColor,
        existingWebNoteJSON: String?,
        plainText: String? = nil,
        localID: UUID? = nil,
        modifiedAt: Date = Date()
    ) -> [[String: Any]] {
        [
            [
                "id": pidLidNoteColorPropertyId,
                "value": "\(pidLidNoteColorCode(for: color))"
            ],
            [
                "id": pidTagIconIndexPropertyId,
                "value": "\(pidTagIconIndex(for: color))"
            ],
            [
                "id": webNoteJSONPropertyId,
                "value": webNoteJSON(
                    setting: color,
                    existing: existingWebNoteJSON,
                    plainText: plainText,
                    localID: localID,
                    modifiedAt: modifiedAt
                )
            ]
        ]
    }

    static func extractNoteColor(fromExtendedProperties props: [[String: Any]]) -> (color: NoteColor, webNoteJSON: String?) {
        var lidColor: NoteColor?
        var iconColor: NoteColor?
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
            } else if isPidTagIconIndexProperty(propId),
                      let value = prop["value"] as? String,
                      let code = Int(value) {
                iconColor = noteColor(fromPidTagIconIndex: code)
            }
        }
        return (webColor ?? lidColor ?? iconColor ?? .yellow, webJSON)
    }

    /// 仅用于诊断：颜色判定所依据的原始线上值（不改变行为）。
    /// `source` 表示由哪个字段决定颜色："_Note" | "0x8B00" | "0x1080" | "default(yellow)"。
    static func rawColorCodes(fromExtendedProperties props: [[String: Any]]) -> (webCode: Int?, lidCode: Int?, source: String) {
        var web: Int?
        var lid: Int?
        var icon: Int?
        for prop in props {
            guard let propId = prop["id"] as? String, let value = prop["value"] as? String else { continue }
            if isWebNoteJSONProperty(propId) {
                if let data = value.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let raw = obj["color"]
                    if !isJSONBoolean(raw) {
                        if let v = raw as? Int { web = v }
                        else if let v = raw as? NSNumber { web = v.intValue }
                        else if let v = raw as? String { web = Int(v) }
                    }
                }
            } else if isPidLidNoteColorProperty(propId) {
                lid = Int(value)
            } else if isPidTagIconIndexProperty(propId) {
                icon = Int(value)
            }
        }
        let source = web != nil ? "_Note" : (lid != nil ? "0x8B00" : (icon != nil ? "0x1080" : "default(yellow)"))
        return (web, lid, source)
    }

    // MARK: - Internal Helpers

    private static var defaultAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor
        ]
    }

    private static func colorToHex(_ color: NSColor) -> String? {
        // Check dynamic semantic colors BEFORE sRGB conversion so checked todos (`secondaryLabelColor`)
        // and default text/link colors are never baked as opaque #FFFFFF/#000000 across themes.
        if color == NSColor.textColor ||
            color == NSColor.labelColor ||
            color == NSColor.secondaryLabelColor ||
            color == NSColor.tertiaryLabelColor ||
            color == NSColor.linkColor {
            return nil
        }
        guard let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0.05 else { return nil }
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
        guard string.contains("&") else { return string }
        var output = ""
        output.reserveCapacity(string.count)
        var index = string.startIndex
        let end = string.endIndex

        while index < end {
            let ch = string[index]
            if ch == "&" {
                let searchStart = string.index(after: index)
                var scan = searchStart
                var steps = 0
                var semi: String.Index?
                while scan < end && steps < 14 {
                    let c = string[scan]
                    if c == ";" {
                        semi = scan
                        break
                    }
                    if c == "&" || c.isWhitespace || c == "<" {
                        break
                    }
                    scan = string.index(after: scan)
                    steps += 1
                }
                if let semi, let decoded = decodeSingleEntity(string[searchStart..<semi]) {
                    output.append(decoded)
                    index = string.index(after: semi)
                    continue
                }
            }
            output.append(ch)
            index = string.index(after: index)
        }
        return output
    }

    private static let namedEntities: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": " ",
        "mdash": "—",
        "ndash": "–",
        "hellip": "…",
        "bull": "•",
        "ldquo": "“",
        "rdquo": "”",
        "lsquo": "‘",
        "rsquo": "’",
        "copy": "©",
        "reg": "®",
        "trade": "™"
    ]

    private static func decodeSingleEntity(_ body: Substring) -> String? {
        guard !body.isEmpty else { return nil }
        if body.first == "#" {
            let num = body.dropFirst()
            guard !num.isEmpty else { return nil }
            let value: UInt32?
            if num.first == "x" || num.first == "X" {
                value = UInt32(num.dropFirst(), radix: 16)
            } else {
                value = UInt32(num, radix: 10)
            }
            guard let scalarValue = value else { return nil }
            if scalarValue == 160 { return " " }
            guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[body.lowercased()]
    }

    /// Offline HTML tokenizer & attributed-string builder (no WebKit, no network, no filesystem, no RunLoop pumping).
    private enum OfflineHTMLParser {
        private static let hiddenTextKey = NSAttributedString.Key("com.stickynotes.hiddenText")
        private static let skipContainerTags: Set<String> = [
            "head", "style", "script", "noscript", "iframe", "object", "embed", "applet", "svg", "math", "template"
        ]
        private static let blockTags: Set<String> = [
            "div", "p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "tr"
        ]
        private static let voidTags: Set<String> = [
            "br", "hr", "img", "meta", "link", "input", "area", "base", "col", "source", "track", "wbr"
        ]
        private static let maxInlineImageBytes = 5 * 1024 * 1024

        private struct StyleState {
            var bold = false
            var italic = false
            var underline = false
            var strikethrough = false
            var foregroundColor: NSColor?
            var hidden = false
            var link: URL?
        }

        static func parse(_ html: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            result.beginEditing()
            defer { result.endEditing() }

            let hasMarkup = html.contains("<") && html.contains(">")
            var styleStack: [(tag: String, state: StyleState)] = []
            var skipStack: [String] = []
            var preDepth = 0
            var pendingBlockBreak = false
            var hasEmittedContent = false
            var lastCharWasNewline = false

            func currentStyle() -> StyleState {
                styleStack.last?.state ?? StyleState()
            }

            func attributes(for state: StyleState) -> [NSAttributedString.Key: Any] {
                var font = NSFont.systemFont(ofSize: 14)
                var traits: NSFontDescriptor.SymbolicTraits = []
                if state.bold { traits.insert(.bold) }
                if state.italic { traits.insert(.italic) }
                if !traits.isEmpty {
                    let desc = font.fontDescriptor.withSymbolicTraits(traits)
                    font = NSFont(descriptor: desc, size: 14) ?? font
                }

                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: state.hidden
                        ? NSColor(white: 0.15, alpha: 1.0)
                        : (state.foregroundColor ?? NSColor.textColor)
                ]
                if state.hidden {
                    attrs[.backgroundColor] = NSColor(white: 0.15, alpha: 1.0)
                    attrs[hiddenTextKey] = true
                }
                if state.underline {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if state.strikethrough {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let link = state.link {
                    attrs[.link] = link
                }
                return attrs
            }

            func flushBlockBreakIfNeeded() {
                if pendingBlockBreak && hasEmittedContent && !lastCharWasNewline {
                    result.append(NSAttributedString(string: "\n", attributes: attributes(for: StyleState())))
                    lastCharWasNewline = true
                }
                pendingBlockBreak = false
            }

            func emitText(_ raw: Substring) {
                guard skipStack.isEmpty, !raw.isEmpty else { return }
                var text = NoteConverter.unescapeHtml(String(raw))
                if hasMarkup && preDepth == 0 {
                    if text.contains("\n") || text.contains("\r") {
                        if text.allSatisfy({ $0.isWhitespace }) {
                            return
                        }
                        text = text
                            .replacingOccurrences(of: "\r\n", with: " ")
                            .replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\r", with: " ")
                    }
                }
                guard !text.isEmpty else { return }
                flushBlockBreakIfNeeded()
                result.append(NSAttributedString(string: text, attributes: attributes(for: currentStyle())))
                hasEmittedContent = true
                lastCharWasNewline = text.hasSuffix("\n")
            }

            func emitNewline() {
                guard skipStack.isEmpty else { return }
                flushBlockBreakIfNeeded()
                result.append(NSAttributedString(string: "\n", attributes: attributes(for: currentStyle())))
                hasEmittedContent = true
                lastCharWasNewline = true
            }

            func emitInlineDataImageIfSafe(_ src: String) {
                guard skipStack.isEmpty else { return }
                let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                guard lower.hasPrefix("data:image/"),
                      let commaIdx = trimmed.firstIndex(of: ",") else { return }
                let header = lower[..<commaIdx]
                let allowedPrefixes = ["data:image/png", "data:image/jpeg", "data:image/jpg", "data:image/gif", "data:image/webp"]
                guard header.contains(";base64"),
                      allowedPrefixes.contains(where: { header.hasPrefix($0) }) else { return }
                let b64 = String(trimmed[trimmed.index(after: commaIdx)...])
                guard b64.utf8.count <= (maxInlineImageBytes * 4) / 3 + 16,
                      let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                      data.count <= maxInlineImageBytes,
                      let image = NSImage(data: data) else { return }
                flushBlockBreakIfNeeded()
                let attachment = NSTextAttachment()
                attachment.image = image
                let attachStr = NSMutableAttributedString(attachment: attachment)
                attachStr.addAttributes(attributes(for: currentStyle()), range: NSRange(location: 0, length: attachStr.length))
                result.append(attachStr)
                hasEmittedContent = true
                lastCharWasNewline = false
            }

            var index = html.startIndex
            let end = html.endIndex

            while index < end {
                guard let lt = html[index...].firstIndex(of: "<") else {
                    emitText(html[index..<end])
                    break
                }
                if lt > index {
                    emitText(html[index..<lt])
                }

                // Comment: <!-- ... -->
                if html[lt...].hasPrefix("<!--") {
                    let afterStart = html.index(lt, offsetBy: 4, limitedBy: end) ?? end
                    if let closeRange = html[afterStart...].range(of: "-->") {
                        index = closeRange.upperBound
                    } else {
                        break
                    }
                    continue
                }

                // Find closing '>' while respecting quoted attribute values
                guard let gt = findTagEnd(in: html, from: lt) else {
                    emitText(html[lt..<end])
                    break
                }

                let inner = html[html.index(after: lt)..<gt].trimmingCharacters(in: .whitespacesAndNewlines)
                index = html.index(after: gt)

                guard !inner.isEmpty else { continue }
                if inner.hasPrefix("!") || inner.hasPrefix("?") { continue }

                let isClosing = inner.hasPrefix("/")
                let selfClosing = !isClosing && inner.hasSuffix("/")
                let tagBody = isClosing
                    ? inner.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    : (selfClosing ? inner.dropLast().trimmingCharacters(in: .whitespacesAndNewlines) : inner)

                let nameEnd = tagBody.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? tagBody.endIndex
                let tagName = tagBody[..<nameEnd].lowercased()
                guard !tagName.isEmpty else { continue }

                if isClosing {
                    if !skipStack.isEmpty {
                        if let matchIdx = skipStack.lastIndex(of: tagName) {
                            skipStack.removeSubrange(matchIdx...)
                        }
                        continue
                    }
                    if tagName == "pre" {
                        preDepth = max(0, preDepth - 1)
                    }
                    if blockTags.contains(tagName), hasEmittedContent, !lastCharWasNewline {
                        pendingBlockBreak = true
                    }
                    if let matchIdx = styleStack.lastIndex(where: { $0.tag == tagName }) {
                        styleStack.remove(at: matchIdx)
                    }
                    continue
                }

                if !skipStack.isEmpty {
                    if skipContainerTags.contains(tagName) && !selfClosing {
                        skipStack.append(tagName)
                    }
                    continue
                }

                if skipContainerTags.contains(tagName) {
                    if !selfClosing {
                        skipStack.append(tagName)
                    }
                    continue
                }

                if tagName == "br" {
                    emitNewline()
                    continue
                }

                let attrSubstring = nameEnd < tagBody.endIndex ? tagBody[nameEnd...] : ""
                let attrs = parseAttributes(attrSubstring)

                if tagName == "img" {
                    if let src = attrs["src"] {
                        emitInlineDataImageIfSafe(src)
                    }
                    continue
                }

                if blockTags.contains(tagName) {
                    if hasEmittedContent && !lastCharWasNewline {
                        pendingBlockBreak = true
                    }
                    if tagName == "pre" && !selfClosing {
                        preDepth += 1
                    }
                }

                if voidTags.contains(tagName) || selfClosing {
                    continue
                }

                var nextState = currentStyle()
                switch tagName {
                case "b", "strong":
                    nextState.bold = true
                case "i", "em":
                    nextState.italic = true
                case "u":
                    nextState.underline = true
                case "s", "strike", "del":
                    nextState.strikethrough = true
                case "a":
                    if let href = attrs["href"] {
                        let decodedHref = NoteConverter.unescapeHtml(href).trimmingCharacters(in: .whitespacesAndNewlines)
                        if let url = URL(string: decodedHref), SafeURLPolicy.isAllowed(url) {
                            nextState.link = url
                            nextState.underline = true
                            nextState.foregroundColor = NSColor.linkColor
                        }
                    }
                case "font":
                    if let colorVal = attrs["color"], let parsedColor = parseCSSColor(colorVal) {
                        nextState.foregroundColor = normalizeImportedColor(parsedColor)
                    }
                default:
                    break
                }

                if attrs["data-stickynotes-hidden"] == "1" {
                    nextState.hidden = true
                }

                if let styleAttr = attrs["style"] {
                    applyInlineCSS(NoteConverter.unescapeHtml(styleAttr), to: &nextState)
                }

                styleStack.append((tagName, nextState))
            }

            NoteConverter.trimTrailingHTMLNewlines(in: result)
            return result
        }

        private static func findTagEnd(in html: String, from start: String.Index) -> String.Index? {
            var idx = html.index(after: start)
            var quote: Character?
            while idx < html.endIndex {
                let c = html[idx]
                if let q = quote {
                    if c == q { quote = nil }
                } else {
                    if c == "\"" || c == "'" {
                        quote = c
                    } else if c == ">" {
                        return idx
                    }
                }
                idx = html.index(after: idx)
            }
            return nil
        }

        private static func parseAttributes(_ raw: Substring) -> [String: String] {
            var attrs: [String: String] = [:]
            var idx = raw.startIndex
            let end = raw.endIndex

            while idx < end {
                while idx < end && raw[idx].isWhitespace { idx = raw.index(after: idx) }
                guard idx < end else { break }

                let keyStart = idx
                while idx < end && !raw[idx].isWhitespace && raw[idx] != "=" && raw[idx] != "/" {
                    idx = raw.index(after: idx)
                }
                let key = raw[keyStart..<idx].lowercased()
                while idx < end && raw[idx].isWhitespace { idx = raw.index(after: idx) }

                guard !key.isEmpty else {
                    if idx < end { idx = raw.index(after: idx) }
                    continue
                }

                if idx < end && raw[idx] == "=" {
                    idx = raw.index(after: idx)
                    while idx < end && raw[idx].isWhitespace { idx = raw.index(after: idx) }
                    guard idx < end else { break }
                    if raw[idx] == "\"" || raw[idx] == "'" {
                        let quote = raw[idx]
                        idx = raw.index(after: idx)
                        let valStart = idx
                        while idx < end && raw[idx] != quote { idx = raw.index(after: idx) }
                        attrs[key] = String(raw[valStart..<idx])
                        if idx < end { idx = raw.index(after: idx) }
                    } else {
                        let valStart = idx
                        while idx < end && !raw[idx].isWhitespace { idx = raw.index(after: idx) }
                        attrs[key] = String(raw[valStart..<idx])
                    }
                } else {
                    attrs[key] = ""
                }
            }
            return attrs
        }

        private static func applyInlineCSS(_ css: String, to state: inout StyleState) {
            for decl in css.split(separator: ";") {
                guard let colon = decl.firstIndex(of: ":") else { continue }
                let prop = decl[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = decl[decl.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch prop {
                case "font-weight":
                    if val == "bold" || val == "bolder" || (Int(val) ?? 0) >= 600 {
                        state.bold = true
                    } else if val == "normal" || (Int(val) ?? 700) < 600 {
                        state.bold = false
                    }
                case "font-style":
                    if val == "italic" || val == "oblique" {
                        state.italic = true
                    } else if val == "normal" {
                        state.italic = false
                    }
                case "text-decoration", "text-decoration-line":
                    if val.contains("underline") { state.underline = true }
                    if val.contains("line-through") { state.strikethrough = true }
                case "color":
                    if let parsed = parseCSSColor(val) {
                        state.foregroundColor = normalizeImportedColor(parsed)
                    }
                default:
                    break
                }
            }
        }

        private static func parseCSSColor(_ raw: String) -> NSColor? {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.hasPrefix("#") {
                let hex = String(s.dropFirst())
                if hex.count == 6, let val = UInt32(hex, radix: 16) {
                    let r = CGFloat((val >> 16) & 0xFF) / 255.0
                    let g = CGFloat((val >> 8) & 0xFF) / 255.0
                    let b = CGFloat(val & 0xFF) / 255.0
                    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
                } else if hex.count == 3, let val = UInt32(hex, radix: 16) {
                    let r = CGFloat(((val >> 8) & 0xF) * 17) / 255.0
                    let g = CGFloat(((val >> 4) & 0xF) * 17) / 255.0
                    let b = CGFloat((val & 0xF) * 17) / 255.0
                    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
                }
            } else if s.hasPrefix("rgb(") || s.hasPrefix("rgba(") {
                guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
                let parts = s[s.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3,
                      let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
                let a = parts.count >= 4 ? (Double(parts[3]) ?? 1.0) : 1.0
                return NSColor(srgbRed: CGFloat(min(max(r, 0), 255)) / 255.0,
                               green: CGFloat(min(max(g, 0), 255)) / 255.0,
                               blue: CGFloat(min(max(b, 0), 255)) / 255.0,
                               alpha: CGFloat(min(max(a, 0), 1)))
            }
            switch s {
            case "black": return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            case "white": return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            case "red": return NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            case "green": return NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1)
            case "blue": return NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            case "gray", "grey": return NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            case "orange": return NSColor(srgbRed: 1, green: 0.65, blue: 0, alpha: 1)
            case "purple": return NSColor(srgbRed: 0.5, green: 0, blue: 0.5, alpha: 1)
            case "pink": return NSColor(srgbRed: 1, green: 0.75, blue: 0.8, alpha: 1)
            case "yellow": return NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
            default: return nil
            }
        }

        private static func normalizeImportedColor(_ color: NSColor) -> NSColor {
            guard let rgb = color.usingColorSpace(.sRGB) else { return color }
            let isNearBlack = rgb.redComponent < 0.05 && rgb.greenComponent < 0.05 && rgb.blueComponent < 0.05 && rgb.alphaComponent > 0.9
            let isNearWhite = rgb.redComponent > 0.95 && rgb.greenComponent > 0.95 && rgb.blueComponent > 0.95 && rgb.alphaComponent > 0.9
            if isNearBlack || isNearWhite {
                return NSColor.textColor
            }
            return color
        }
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

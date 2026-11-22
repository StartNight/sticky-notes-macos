import SwiftUI

struct NoteTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var plainText: String
    let externalSyncVersion: Int
    let backgroundColor: NSColor
    let proxy: TextEditorProxy
    let onTextChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = ClickableTextView()
        textView.proxy = proxy
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.allowsImageEditing = true
        textView.importsGraphics = true
        textView.drawsBackground = true
        textView.backgroundColor = backgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.font = NSFont.systemFont(ofSize: 14)
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor
        ]

        if attributedText.length > 0 {
            textView.textStorage?.setAttributedString(attributedText)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.lastAppliedExternalVersion = externalSyncVersion
        proxy.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.backgroundColor = backgroundColor

        if proxy.textView !== textView {
            proxy.textView = textView
        }

        // Only replace textStorage on genuine external updates (initial load / cloud sync),
        // never on local keystrokes (preserves NSUndoManager, typingAttributes, images, and IME).
        guard context.coordinator.lastAppliedExternalVersion != externalSyncVersion else { return }
        // Never overwrite while CJK/dead-key IME composition is active.
        if textView.hasMarkedText() { return }

        context.coordinator.lastAppliedExternalVersion = externalSyncVersion
        let newLength = attributedText.length
        let clampedRanges = textView.selectedRanges.compactMap { value -> NSValue? in
            let range = value.rangeValue
            let safeLocation = min(range.location, newLength)
            let safeLength = min(range.length, max(0, newLength - safeLocation))
            return NSValue(range: NSRange(location: safeLocation, length: safeLength))
        }
        textView.textStorage?.setAttributedString(attributedText)
        textView.selectedRanges = clampedRanges.isEmpty ? [NSValue(range: NSRange(location: newLength, length: 0))] : clampedRanges
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor
        weak var textView: NSTextView?
        var lastAppliedExternalVersion: Int = -1

        init(_ parent: NoteTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Store an immutable snapshot instead of aliasing the live mutable NSTextStorage.
            parent.attributedText = NSAttributedString(attributedString: textView.attributedString())
            parent.plainText = textView.string
            parent.onTextChange()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = SafeURLPolicy.validatedURL(from: link) {
                NSWorkspace.shared.open(url)
            }
            // Always return true so AppKit never falls back to opening rejected schemes (file://, smb://, etc.).
            return true
        }
    }
}

// MARK: - Custom NSTextView for click handling

final class ClickableTextView: NSTextView {
    var proxy: TextEditorProxy?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            if window.firstResponder == nil || window.firstResponder === window {
                window.makeFirstResponder(self)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        let text = string as NSString

        if charIndex != NSNotFound, charIndex < text.length {
            let clickRange = NSRange(location: charIndex, length: 0)
            let lineRange = text.lineRange(for: clickRange)
            let lineText = text.substring(with: lineRange)

            // Handle todo checkbox clicks (click near beginning of line)
            if (lineText.hasPrefix("☐ ") || lineText.hasPrefix("☑ ")),
               let layoutManager, let textContainer,
               lineRange.location < text.length {
                let prefixCharRange = NSRange(location: lineRange.location, length: 1)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: prefixCharRange, actualCharacterRange: nil)
                if glyphRange.length > 0, NSMaxRange(glyphRange) <= layoutManager.numberOfGlyphs {
                    let lineStartPoint = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                    let relativeX = point.x - textContainerOrigin.x - lineStartPoint.origin.x
                    if relativeX >= -4 && relativeX < 20 {
                        proxy?.toggleTodoAt(characterIndex: charIndex)
                        return
                    }
                }
            }

            // Handle hidden text reveal
            if let storage = textStorage {
                var isHidden = false
                let attrRange = NSRange(location: charIndex, length: 1)
                if attrRange.location + attrRange.length <= storage.length {
                    storage.enumerateAttribute(.hiddenText, in: attrRange) { value, _, _ in
                        if value as? Bool == true {
                            isHidden = true
                        }
                    }
                }
                if isHidden {
                    proxy?.revealHiddenTextAt(characterIndex: charIndex)
                    return
                }
            }
        }

        super.mouseDown(with: event)
    }

    /// Restrict pasteboard handling: parse pasted HTML offline (zero network/file subresource loading),
    /// downscale oversized images, and strip unsafe link schemes and non-NSSecureCoding attributes.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let html = pb.string(forType: .html), !html.isEmpty {
            let safeAttr = NoteConverter.htmlToAttributedString(html)
            insertSanitizedAttributedString(safeAttr)
            return
        }
        if let rtfData = pb.data(forType: .rtf),
           let rtfAttr = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            insertSanitizedAttributedString(Self.sanitizeAttributedString(rtfAttr))
            return
        }
        if let image = NSImage(pasteboard: pb), let resized = Self.downscaledImage(image, maxDimension: 1600) {
            let attachment = NSTextAttachment()
            attachment.image = resized
            let attachStr = NSMutableAttributedString(attachment: attachment)
            attachStr.addAttributes([
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.textColor
            ], range: NSRange(location: 0, length: attachStr.length))
            insertSanitizedAttributedString(attachStr)
            return
        }
        if let plain = pb.string(forType: .string) {
            let attr = NSAttributedString(string: plain, attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.textColor
            ])
            insertSanitizedAttributedString(attr)
            return
        }
        super.pasteAsPlainText(sender)
    }

    private func insertSanitizedAttributedString(_ attrStr: NSAttributedString) {
        let range = selectedRange()
        guard let storage = textStorage,
              range.location != NSNotFound,
              NSMaxRange(range) <= storage.length else { return }
        guard shouldChangeText(in: range, replacementString: attrStr.string) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: attrStr)
        storage.endEditing()
        setSelectedRange(NSRange(location: range.location + attrStr.length, length: 0))
        didChangeText()
    }

    static func sanitizeAttributedString(_ input: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(string: input.string)
        out.beginEditing()
        defer { out.endEditing() }
        let fullRange = NSRange(location: 0, length: input.length)
        input.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            var clean: [NSAttributedString.Key: Any] = [
                .font: (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14),
                .foregroundColor: (attrs[.foregroundColor] as? NSColor) ?? NSColor.textColor
            ]
            if let underline = attrs[.underlineStyle] as? Int, underline != 0 {
                clean[.underlineStyle] = underline
            }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 {
                clean[.strikethroughStyle] = strike
            }
            if let para = attrs[.paragraphStyle] as? NSParagraphStyle {
                clean[.paragraphStyle] = para
            }
            if let bg = attrs[.backgroundColor] as? NSColor {
                clean[.backgroundColor] = bg
            }
            if let hidden = attrs[.hiddenText] as? Bool, hidden {
                clean[.hiddenText] = true
            }
            if let linkVal = attrs[.link], let safeURL = SafeURLPolicy.validatedURL(from: linkVal) {
                clean[.link] = safeURL
            }
            if let attach = attrs[.attachment] as? NSTextAttachment {
                if let img = attach.image ?? attach.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)),
                   let resized = downscaledImage(img, maxDimension: 1600) {
                    let safeAttach = NSTextAttachment()
                    safeAttach.image = resized
                    clean[.attachment] = safeAttach
                }
            }
            out.setAttributes(clean, range: range)
        }
        return out
    }

    private static func downscaledImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let newSize = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let target = NSImage(size: newSize)
        target.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        target.unlockFocus()
        return target
    }

    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() {
            super.insertNewline(sender)
            return
        }
        let line = currentLineState()
        let cursorLocation = selectedRange().location

        if let prefix = line.listPrefix {
            if line.isEmptyListItem {
                exitListPrefix(on: line.range)
                return
            }
            let prefixEnd = line.range.location + (prefix.rawValue as NSString).length
            guard cursorLocation != NSNotFound, cursorLocation >= prefixEnd else {
                super.insertNewline(sender)
                return
            }
            super.insertNewline(sender)
            if prefix == .todoDone {
                resetTypingAttributesToDefault()
            }
            insertText(prefix.continuation, replacementRange: selectedRange())
        } else if line.text.isEmpty {
            // Double-enter: previous line was already empty — clear all formatting
            super.insertNewline(sender)
            resetTypingAttributesToDefault()
        } else {
            super.insertNewline(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        if hasMarkedText() {
            super.insertTab(sender)
            return
        }
        let line = currentLineState()
        if line.isEmptyListItem {
            exitListPrefix(on: line.range)
            return
        }
        super.insertTab(sender)
    }

    // MARK: - List-line handling

    /// The list-prefix markers recognised by auto-continuation.
    /// Each entry maps the detected marker to the marker used when continuing
    /// to a new line (checked todos continue as unchecked).
    private enum ListPrefix: String, CaseIterable {
        case bullet = "• "
        case todo = "☐ "
        case todoDone = "☑ "

        var continuation: String {
            switch self {
            case .bullet: return Self.bullet.rawValue
            case .todo, .todoDone: return Self.todo.rawValue
            }
        }
    }

    private struct LineState {
        let range: NSRange
        let text: String
        let listPrefix: ListPrefix?

        var isEmptyListItem: Bool {
            guard let listPrefix else { return false }
            return String(text.dropFirst(listPrefix.rawValue.count))
                .trimmingCharacters(in: .whitespaces)
                .isEmpty
        }
    }

    private func currentLineState() -> LineState {
        let nsString = string as NSString
        let rawLoc = selectedRange().location
        let cursorLocation = rawLoc == NSNotFound ? nsString.length : min(max(0, rawLoc), nsString.length)
        let range = nsString.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let text = nsString.substring(with: range).trimmingCharacters(in: .newlines)
        let prefix = ListPrefix.allCases.first(where: { text.hasPrefix($0.rawValue) })
        return LineState(range: range, text: text, listPrefix: prefix)
    }

    /// Replace a list-prefix line with an empty plain line, preserving the
    /// trailing newline when present so paragraphs don't collapse into each
    /// other. Keeps caret on the emptied line and resets typing attributes.
    private func exitListPrefix(on lineRange: NSRange) {
        let preserved = preservedNewline(for: lineRange)
        insertText(preserved, replacementRange: lineRange)
        let safeLoc = min(lineRange.location, (string as NSString).length)
        setSelectedRange(NSRange(location: safeLoc, length: 0))
        resetTypingAttributesToDefault()
    }

    /// Returns "\n" if `lineRange` ends on a newline, otherwise "".
    /// Safe for zero-length ranges (returns "") and bounds-checked against
    /// the backing string so it can't read past the end.
    private func preservedNewline(for lineRange: NSRange) -> String {
        guard lineRange.length > 0 else { return "" }
        let nsString = string as NSString
        let lastCharIndex = lineRange.location + lineRange.length - 1
        guard lastCharIndex < nsString.length else { return "" }
        let lastChar = nsString.substring(with: NSRange(location: lastCharIndex, length: 1))
        return lastChar == "\n" ? "\n" : ""
    }

    private func resetTypingAttributesToDefault() {
        typingAttributes = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor
        ]
    }
}

import AppKit

extension NSAttributedString.Key {
    static let hiddenText = NSAttributedString.Key("com.stickynotes.hiddenText")
}

@MainActor
final class TextEditorProxy {
    weak var textView: NSTextView?

    // MARK: - Focus Management

    /// Return the textView's current selection, restoring first-responder so the
    /// caret remains where the user left it. NSTextView preserves its selection
    /// across focus loss (e.g. when a toolbar button briefly takes focus), so we
    /// trust `selectedRange()` directly instead of caching a stale range.
    private func restoreFocusAndRange() -> NSRange? {
        guard let textView else { return nil }
        textView.window?.makeFirstResponder(textView)
        return textView.selectedRange()
    }

    private func clampedRange(_ range: NSRange, length: Int) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.location <= length else { return nil }
        let safeLen = min(max(0, range.length), length - range.location)
        return NSRange(location: range.location, length: safeLen)
    }

    /// Registers an undoable attribute-only mutation on `textView` via `shouldChangeText` / `didChangeText`.
    private func applyAttributeEdit(in textView: NSTextView, range: NSRange, mutate: (NSTextStorage) -> Void) {
        guard let storage = textView.textStorage,
              let safeRange = clampedRange(range, length: storage.length),
              safeRange.length > 0 else { return }
        let before = storage.attributedSubstring(from: safeRange).copy() as! NSAttributedString
        guard textView.shouldChangeText(in: safeRange, replacementString: nil) else { return }
        storage.beginEditing()
        mutate(storage)
        storage.endEditing()
        let after = storage.attributedSubstring(from: safeRange).copy() as! NSAttributedString
        if let undoManager = textView.undoManager {
            undoManager.registerUndo(withTarget: textView) { tv in
                guard let st = tv.textStorage, NSMaxRange(safeRange) <= st.length else { return }
                st.beginEditing()
                st.replaceCharacters(in: safeRange, with: before)
                st.endEditing()
                tv.didChangeText()
                tv.undoManager?.registerUndo(withTarget: tv) { tv2 in
                    guard let st2 = tv2.textStorage, NSMaxRange(safeRange) <= st2.length else { return }
                    st2.beginEditing()
                    st2.replaceCharacters(in: safeRange, with: after)
                    st2.endEditing()
                    tv2.didChangeText()
                }
            }
        }
        textView.didChangeText()
    }

    // MARK: - Font Trait Formatting (DRY: single method for B/I)

    func toggleBold() { toggleFontTrait(.boldFontMask, symbolicTrait: .bold) }
    func toggleItalic() { toggleFontTrait(.italicFontMask, symbolicTrait: .italic) }

    private func toggleFontTrait(_ trait: NSFontTraitMask, symbolicTrait: NSFontDescriptor.SymbolicTraits) {
        guard let textView, let storage = textView.textStorage else { return }
        guard let rawRange = restoreFocusAndRange(),
              let range = clampedRange(rawRange, length: storage.length) else { return }

        if range.length == 0 {
            var attrs = textView.typingAttributes
            let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            if font.fontDescriptor.symbolicTraits.contains(symbolicTrait) {
                attrs[.font] = NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            } else {
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: trait)
            }
            textView.typingAttributes = attrs
            return
        }

        // Uniform toggle: remove trait only if ALL runs in the selection already have it; otherwise apply uniformly.
        var allHaveTrait = true
        storage.enumerateAttribute(.font, in: range) { value, _, stop in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            if !font.fontDescriptor.symbolicTraits.contains(symbolicTrait) {
                allHaveTrait = false
                stop.pointee = true
            }
        }

        applyAttributeEdit(in: textView, range: range) { storage in
            storage.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                let newFont = allHaveTrait
                    ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                    : NSFontManager.shared.convert(font, toHaveTrait: trait)
                storage.addAttribute(.font, value: newFont, range: attrRange)
            }
        }
        textView.setSelectedRange(range)
    }

    // MARK: - Attribute Style Formatting (DRY: single method for U/S)

    func toggleUnderline() { toggleAttributeStyle(.underlineStyle) }
    func toggleStrikethrough() { toggleAttributeStyle(.strikethroughStyle) }

    private func toggleAttributeStyle(_ key: NSAttributedString.Key) {
        guard let textView, let storage = textView.textStorage else { return }
        guard let rawRange = restoreFocusAndRange(),
              let range = clampedRange(rawRange, length: storage.length) else { return }

        if range.length == 0 {
            var attrs = textView.typingAttributes
            let current = (attrs[key] as? Int) ?? 0
            attrs[key] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attrs
            return
        }

        var allHaveStyle = true
        storage.enumerateAttribute(key, in: range) { value, _, stop in
            if ((value as? Int) ?? 0) == 0 {
                allHaveStyle = false
                stop.pointee = true
            }
        }
        let targetValue = allHaveStyle ? 0 : NSUnderlineStyle.single.rawValue

        applyAttributeEdit(in: textView, range: range) { storage in
            storage.addAttribute(key, value: targetValue, range: range)
        }
        textView.setSelectedRange(range)
    }

    // MARK: - List Formatting (preserves rich formatting, hidden text, and inline attachments)

    private static let allListPrefixes = ["• ", "☐ ", "☑ "]

    func toggleBulletList() { toggleLinePrefix(prefix: "• ", matchPrefixes: ["• "]) }

    func toggleTodoList() { toggleLinePrefix(prefix: "☐ ", matchPrefixes: ["☐ ", "☑ "]) }

    private func toggleLinePrefix(prefix: String, matchPrefixes: [String]) {
        guard let textView, let storage = textView.textStorage else { return }
        guard let rawRange = restoreFocusAndRange(),
              let range = clampedRange(rawRange, length: storage.length) else { return }
        let text = textView.string as NSString
        let lineRange = text.lineRange(for: range)

        // Collect individual line ranges (without trailing newline) within `lineRange`.
        var lineRanges: [NSRange] = []
        var cursor = lineRange.location
        let end = NSMaxRange(lineRange)
        if cursor == end {
            lineRanges.append(NSRange(location: cursor, length: 0))
        } else {
            while cursor < end {
                let single = text.lineRange(for: NSRange(location: cursor, length: 0))
                var contentLen = single.length
                if contentLen > 0 && text.substring(with: NSRange(location: single.location + contentLen - 1, length: 1)) == "\n" {
                    contentLen -= 1
                }
                lineRanges.append(NSRange(location: single.location, length: contentLen))
                cursor = NSMaxRange(single)
            }
        }

        let nonEmptyRanges = lineRanges.filter { $0.length > 0 }

        // Cursor on a blank line (or selection of only blank lines): insert the prefix at the caret.
        if nonEmptyRanges.isEmpty {
            textView.insertText(prefix, replacementRange: NSRange(location: range.location, length: 0))
            return
        }

        let allPrefixed = nonEmptyRanges.allSatisfy { r in
            let lineStr = text.substring(with: r)
            return matchPrefixes.contains(where: { lineStr.hasPrefix($0) })
        }

        // Apply prefix insertions/removals in reverse order so earlier offsets remain valid
        // and rich formatting, hidden spans, and inline attachments on each line remain completely untouched.
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        for r in nonEmptyRanges.reversed() {
            let currentText = textView.string as NSString
            guard r.location <= currentText.length else { continue }
            let clampedLine = NSRange(location: r.location, length: min(r.length, currentText.length - r.location))
            let lineStr = currentText.substring(with: clampedLine)

            if allPrefixed {
                if let matched = matchPrefixes.first(where: { lineStr.hasPrefix($0) }) {
                    let prefixLen = (matched as NSString).length
                    let removeRange = NSRange(location: clampedLine.location, length: min(prefixLen, clampedLine.length))
                    if textView.shouldChangeText(in: removeRange, replacementString: "") {
                        storage.beginEditing()
                        storage.replaceCharacters(in: removeRange, with: "")
                        storage.endEditing()
                        textView.didChangeText()
                    }
                }
            } else if !matchPrefixes.contains(where: { lineStr.hasPrefix($0) }) {
                let otherPrefixes = Self.allListPrefixes.filter { !matchPrefixes.contains($0) }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.textColor
                ]
                if let existingOther = otherPrefixes.first(where: { lineStr.hasPrefix($0) }) {
                    let existingLen = (existingOther as NSString).length
                    let replaceRange = NSRange(location: clampedLine.location, length: min(existingLen, clampedLine.length))
                    if textView.shouldChangeText(in: replaceRange, replacementString: prefix) {
                        storage.beginEditing()
                        storage.replaceCharacters(in: replaceRange, with: NSAttributedString(string: prefix, attributes: attrs))
                        storage.endEditing()
                        textView.didChangeText()
                    }
                } else {
                    let insertRange = NSRange(location: clampedLine.location, length: 0)
                    if textView.shouldChangeText(in: insertRange, replacementString: prefix) {
                        storage.beginEditing()
                        storage.insert(NSAttributedString(string: prefix, attributes: attrs), at: clampedLine.location)
                        storage.endEditing()
                        textView.didChangeText()
                    }
                }
            }
        }
    }

    // MARK: - Todo Toggle (preserves rich formatting, hidden text, and inline attachments)

    func toggleTodoAt(characterIndex: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        guard characterIndex >= 0, characterIndex <= storage.length else { return }
        let text = textView.string as NSString
        let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
        let lineText = text.substring(with: lineRange)

        let checking: Bool
        let replacementPrefix: String
        if lineText.hasPrefix("☐ ") {
            checking = true
            replacementPrefix = "☑ "
        } else if lineText.hasPrefix("☑ ") {
            checking = false
            replacementPrefix = "☐ "
        } else {
            return
        }

        let prefixLen = min(2, lineRange.length)
        let prefixRange = NSRange(location: lineRange.location, length: prefixLen)

        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        // Only replace the 2-char checkbox prefix so rich formatting, links, hidden spans, and inline images survive!
        if textView.shouldChangeText(in: prefixRange, replacementString: replacementPrefix) {
            storage.beginEditing()
            storage.replaceCharacters(in: prefixRange, with: replacementPrefix)
            storage.endEditing()
            textView.didChangeText()
        }

        let updatedText = textView.string as NSString
        let updatedLineRange = updatedText.lineRange(for: NSRange(location: min(lineRange.location, updatedText.length), length: 0))
        guard updatedLineRange.length > 0 else { return }

        applyAttributeEdit(in: textView, range: updatedLineRange) { storage in
            // Skip `.hiddenText` subranges when modifying foreground color so hidden spoilers are never exposed!
            storage.enumerateAttribute(.hiddenText, in: updatedLineRange) { hiddenVal, subRange, _ in
                let isHidden = (hiddenVal as? Bool) == true
                if checking {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: subRange)
                    if !isHidden {
                        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: subRange)
                    }
                } else {
                    storage.removeAttribute(.strikethroughStyle, range: subRange)
                    if !isHidden {
                        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: subRange)
                    }
                }
            }
        }
    }

    // MARK: - Hidden/Spoiler Text

    func toggleHiddenText() {
        guard let textView, let storage = textView.textStorage else { return }
        guard let rawRange = restoreFocusAndRange(),
              let range = clampedRange(rawRange, length: storage.length),
              range.length > 0 else { return }

        var isHidden = false
        if range.location < storage.length {
            let checkLen = min(1, storage.length - range.location)
            storage.enumerateAttribute(.hiddenText, in: NSRange(location: range.location, length: checkLen)) { value, _, stop in
                if value as? Bool == true { isHidden = true; stop.pointee = true }
            }
        }

        applyAttributeEdit(in: textView, range: range) { storage in
            if isHidden {
                storage.removeAttribute(.hiddenText, range: range)
                storage.removeAttribute(.backgroundColor, range: range)
                storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            } else {
                let blockColor = NSColor(white: 0.15, alpha: 1.0)
                storage.addAttribute(.hiddenText, value: true, range: range)
                storage.addAttribute(.backgroundColor, value: blockColor, range: range)
                storage.addAttribute(.foregroundColor, value: blockColor, range: range)
            }
        }
        textView.setSelectedRange(NSRange(location: min(range.location + range.length, storage.length), length: 0))
    }

    func revealHiddenTextAt(characterIndex: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        guard characterIndex >= 0, characterIndex < storage.length else { return }

        var fullRange = NSRange(location: 0, length: 0)
        let attrValue = storage.attribute(
            .hiddenText,
            at: characterIndex,
            longestEffectiveRange: &fullRange,
            in: NSRange(location: 0, length: storage.length)
        )
        guard (attrValue as? Bool) == true, fullRange.length > 0 else { return }

        applyAttributeEdit(in: textView, range: fullRange) { storage in
            storage.removeAttribute(.hiddenText, range: fullRange)
            storage.removeAttribute(.backgroundColor, range: fullRange)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        }
    }

    // MARK: - Pasteboard

    func paste() { textView?.paste(nil) }
}

/// Forwards system Cut/Copy/Paste/Select All into the note NSTextView.
/// SwiftUI's default Edit menu targets SwiftUI text fields and swallows ⌘V
/// when focus is an AppKit NSViewRepresentable editor (or a toolbar control).
enum NotePasteSupport {
    enum Action {
        case cut, copy, paste, selectAll
    }

    @discardableResult
    static func pasteIntoNote(in window: NSWindow?) -> Bool {
        perform(.paste, in: window)
    }

    @discardableResult
    static func cut(in window: NSWindow?) -> Bool { perform(.cut, in: window) }

    @discardableResult
    static func copy(in window: NSWindow?) -> Bool { perform(.copy, in: window) }

    @discardableResult
    static func selectAll(in window: NSWindow?) -> Bool { perform(.selectAll, in: window) }

    @discardableResult
    static func perform(_ action: Action, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        let selector: Selector
        switch action {
        case .cut: selector = #selector(NSText.cut(_:))
        case .copy: selector = #selector(NSText.copy(_:))
        case .paste: selector = #selector(NSText.paste(_:))
        case .selectAll: selector = #selector(NSText.selectAll(_:))
        }

        if window.firstResponder is NSTextView {
            return NSApp.sendAction(selector, to: nil, from: nil)
        }
        guard let textView = findNoteTextView(in: window.contentView) else {
            return NSApp.sendAction(selector, to: nil, from: nil)
        }
        window.makeFirstResponder(textView)
        switch action {
        case .cut: textView.cut(nil)
        case .copy: textView.copy(nil)
        case .paste: textView.paste(nil)
        case .selectAll: textView.selectAll(nil)
        }
        return true
    }

    static func findNoteTextView(in view: NSView?) -> NSTextView? {
        // Prefer an editable rich-text NSTextView (the note editor) over plain single-line field editors (e.g. Find bar).
        if let rich = findTextView(in: view, requireRichText: true) {
            return rich
        }
        return findTextView(in: view, requireRichText: false)
    }

    private static func findTextView(in view: NSView?, requireRichText: Bool) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView, textView.isEditable, (!requireRichText || textView.isRichText) {
            return textView
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview, requireRichText: requireRichText) { return found }
        }
        return nil
    }
}

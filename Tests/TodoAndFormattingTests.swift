import XCTest
import AppKit

/// 待办清单 / 格式化：通过生产代码 TextEditorProxy 驱动真实 NSTextView（无窗口，逻辑层）。
@MainActor
final class TodoAndFormattingTests: XCTestCase {

    private func makeEditor(_ text: String) -> (TextEditorProxy, NSTextView) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        tv.isEditable = true
        tv.isRichText = true
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        let p = TextEditorProxy()
        p.textView = tv
        return (p, tv)
    }

    func testToggleTodoListAddsAndRemovesPrefix() {
        let (p, tv) = makeEditor("Buy milk")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        p.toggleTodoList()
        XCTAssertEqual(tv.string, "☐ Buy milk")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        p.toggleTodoList()
        XCTAssertEqual(tv.string, "Buy milk")
    }

    func testToggleTodoListMultiLineSelection() {
        let (p, tv) = makeEditor("a\nb\nc")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        p.toggleTodoList()
        XCTAssertEqual(tv.string, "☐ a\n☐ b\n☐ c")
    }

    func testToggleTodoAtChecksAndUnchecks() {
        let (p, tv) = makeEditor("☐ Task one\n☐ Task two")
        p.toggleTodoAt(characterIndex: 0)
        XCTAssertEqual(tv.string, "☑ Task one\n☐ Task two")
        let strike = tv.textStorage?.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue, "完成项应有删除线")
        let secondLineStrike = tv.textStorage?.attribute(.strikethroughStyle, at: 13, effectiveRange: nil) as? Int
        XCTAssertNil(secondLineStrike, "不应影响第二行")

        p.toggleTodoAt(characterIndex: 0)
        XCTAssertEqual(tv.string, "☐ Task one\n☐ Task two")
        XCTAssertNil(tv.textStorage?.attribute(.strikethroughStyle, at: 2, effectiveRange: nil))
    }

    func testToggleTodoAtOnNonTodoLineIsNoop() {
        let (p, tv) = makeEditor("plain line")
        p.toggleTodoAt(characterIndex: 3)
        XCTAssertEqual(tv.string, "plain line")
    }

    func testBulletToggle() {
        let (p, tv) = makeEditor("item")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        p.toggleBulletList()
        XCTAssertEqual(tv.string, "• item")
    }

    func testBoldItalicUnderlineOnSelection() {
        let (p, tv) = makeEditor("Hello world")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        p.toggleBold()
        p.toggleItalic()
        p.toggleUnderline()
        let f = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(f?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertTrue(f?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertEqual(tv.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        let f6 = tv.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        XCTAssertFalse(f6?.fontDescriptor.symbolicTraits.contains(.bold) ?? true, "未选中部分不应加粗")
        // Export to HTML keeps them
        let html = NoteConverter.attributedStringToHtml(tv.attributedString())
        XCTAssertTrue(html.contains("<u><b><i>Hello</i></b></u>"), html)
    }

    func testHiddenTextToggleAndReveal() {
        let (p, tv) = makeEditor("pin 1234")
        tv.setSelectedRange(NSRange(location: 4, length: 4))
        p.toggleHiddenText()
        XCTAssertEqual(tv.textStorage?.attribute(.hiddenText, at: 5, effectiveRange: nil) as? Bool, true)
        p.revealHiddenTextAt(characterIndex: 5)
        XCTAssertNil(tv.textStorage?.attribute(.hiddenText, at: 5, effectiveRange: nil))
    }

    func testRevealHiddenTextCoversLongRunOver500Characters() {
        let secret = String(repeating: "s", count: 800)
        let (p, tv) = makeEditor("pre " + secret + " post")
        tv.setSelectedRange(NSRange(location: 4, length: 800))
        p.toggleHiddenText()
        XCTAssertEqual(tv.textStorage?.attribute(.hiddenText, at: 4, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(tv.textStorage?.attribute(.hiddenText, at: 803, effectiveRange: nil) as? Bool, true)
        // Reveal near start should reveal the entire contiguous 800-char span via longestEffectiveRange
        p.revealHiddenTextAt(characterIndex: 5)
        XCTAssertNil(tv.textStorage?.attribute(.hiddenText, at: 4, effectiveRange: nil))
        XCTAssertNil(tv.textStorage?.attribute(.hiddenText, at: 799, effectiveRange: nil))
        XCTAssertNil(tv.textStorage?.attribute(.hiddenText, at: 803, effectiveRange: nil))
    }

    func testToggleTodoAndBulletPreserveInlineFormattingHiddenTextAndImages() {
        let (p, tv) = makeEditor("")
        let rich = NSMutableAttributedString(string: "☐ ")
        rich.append(NSAttributedString(string: "Bold ", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))
        rich.append(NSAttributedString(string: "secret", attributes: [.font: NSFont.systemFont(ofSize: 14), .hiddenText: true]))
        let img = NSImage(size: NSSize(width: 8, height: 8))
        let att = NSTextAttachment()
        att.image = img
        rich.append(NSAttributedString(attachment: att))
        tv.textStorage?.setAttributedString(rich)

        // Check todo at index 0 — must keep bold, hiddenText, and image attachment intact
        p.toggleTodoAt(characterIndex: 0)
        XCTAssertTrue(tv.string.hasPrefix("☑ "))
        let boldFont = tv.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertEqual(tv.textStorage?.attribute(.hiddenText, at: 7, effectiveRange: nil) as? Bool, true)
        let lastIdx = (tv.string as NSString).length - 1
        XCTAssertNotNil(tv.textStorage?.attribute(.attachment, at: lastIdx, effectiveRange: nil) as? NSTextAttachment)

        // Toggle bullet list on same line — swaps prefix only without losing rich attributes
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        p.toggleBulletList()
        XCTAssertTrue(tv.string.hasPrefix("• "))
        let boldFont2 = tv.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont2?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertEqual(tv.textStorage?.attribute(.hiddenText, at: 7, effectiveRange: nil) as? Bool, true)
        let lastIdx2 = (tv.string as NSString).length - 1
        XCTAssertNotNil(tv.textStorage?.attribute(.attachment, at: lastIdx2, effectiveRange: nil) as? NSTextAttachment)
    }

    func testBoldWorksWhenTextHasNoExplicitFontAttribute() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        tv.isEditable = true
        tv.isRichText = true
        tv.textStorage?.setAttributedString(NSAttributedString(string: "Plain text"))
        let p = TextEditorProxy()
        p.textView = tv

        tv.setSelectedRange(NSRange(location: 0, length: 5))
        p.toggleBold()
        let font = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testFormattingRegistersUndoAction() {
        final class UndoDelegate: NSObject, NSTextViewDelegate {
            let manager = UndoManager()
            func undoManager(for view: NSTextView) -> UndoManager? { manager }
        }
        let undoDelegate = UndoDelegate()
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.delegate = undoDelegate
        tv.textStorage?.setAttributedString(NSAttributedString(string: "Undo me", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        let p = TextEditorProxy()
        p.textView = tv

        tv.setSelectedRange(NSRange(location: 0, length: 4))
        p.toggleUnderline()
        XCTAssertEqual(tv.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertTrue(undoDelegate.manager.canUndo)
        undoDelegate.manager.undo()
        XCTAssertNil(tv.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }
}

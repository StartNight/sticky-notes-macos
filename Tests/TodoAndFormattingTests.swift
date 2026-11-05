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
}

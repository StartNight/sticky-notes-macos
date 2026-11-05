import XCTest
import AppKit

/// 模块 3：富文本转换器（HTML <-> NSAttributedString）
@MainActor
final class NoteConverterTests: XCTestCase {

    private func font(_ traits: NSFontDescriptor.SymbolicTraits = []) -> NSFont {
        let base = NSFont.systemFont(ofSize: 14)
        guard !traits.isEmpty else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: 14) ?? base
    }

    private func traits(_ s: NSAttributedString, at i: Int) -> NSFontDescriptor.SymbolicTraits {
        (s.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits ?? []
    }

    private func range(of sub: String, in s: NSAttributedString) -> NSRange {
        (s.string as NSString).range(of: sub)
    }

    // MARK: AttributedString -> HTML

    func testExportBoldItalicUnderlineStrike() {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "B", attributes: [.font: font(.bold)]))
        s.append(NSAttributedString(string: "I", attributes: [.font: font(.italic)]))
        s.append(NSAttributedString(string: "U", attributes: [.font: font(), .underlineStyle: NSUnderlineStyle.single.rawValue]))
        s.append(NSAttributedString(string: "S", attributes: [.font: font(), .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        let html = NoteConverter.attributedStringToHtml(s)
        XCTAssertTrue(html.contains("<b>B</b>"), html)
        XCTAssertTrue(html.contains("<i>I</i>"), html)
        XCTAssertTrue(html.contains("<u>U</u>"), html)
        XCTAssertTrue(html.contains("<s>S</s>"), html)
        XCTAssertTrue(html.hasPrefix("<div>") && html.hasSuffix("</div>"))
    }

    func testExportEscapesHtmlAndLineBreaks() {
        let s = NSAttributedString(string: "a<b>&\"c\"\nline2", attributes: [.font: font()])
        let html = NoteConverter.attributedStringToHtml(s)
        XCTAssertEqual(html, "<div>a&lt;b&gt;&amp;&quot;c&quot;<br/>line2</div>")
    }

    func testExportEmpty() {
        XCTAssertEqual(NoteConverter.attributedStringToHtml(NSAttributedString(string: "")), "<div></div>")
    }

    // MARK: HTML -> AttributedString

    func testImportBoldItalicUnderline() {
        let a = NoteConverter.htmlToAttributedString("<div><b>Bold</b> <i>Ital</i> <u>Under</u></div>")
        let str = a.string.trimmingCharacters(in: .newlines)
        XCTAssertEqual(str, "Bold Ital Under")
        XCTAssertTrue(traits(a, at: range(of: "Bold", in: a).location).contains(.bold))
        XCTAssertTrue(traits(a, at: range(of: "Ital", in: a).location).contains(.italic))
        let u = a.attribute(.underlineStyle, at: range(of: "Under", in: a).location, effectiveRange: nil) as? Int
        XCTAssertEqual(u, NSUnderlineStyle.single.rawValue)
        let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(f?.pointSize, 14, "字号应归一为 14")
    }

    func testImportEmptyHtml() {
        XCTAssertEqual(NoteConverter.htmlToAttributedString("").length, 0)
    }

    func testImportChineseAndTodoGlyphsUTF8() {
        let a = NoteConverter.htmlToAttributedString("<div>☐ 买牛奶<br/>☑ 已完成</div>")
        XCTAssertEqual(a.string.trimmingCharacters(in: .newlines), "☐ 买牛奶\n☑ 已完成")
    }

    // MARK: Round trips (fidelity)

    func testRoundTripFormattingFidelity() {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Bold", attributes: [.font: font(.bold)]))
        s.append(NSAttributedString(string: " and ", attributes: [.font: font()]))
        s.append(NSAttributedString(string: "Italic", attributes: [.font: font(.italic)]))
        s.append(NSAttributedString(string: " and ", attributes: [.font: font()]))
        s.append(NSAttributedString(string: "Under", attributes: [.font: font(), .underlineStyle: NSUnderlineStyle.single.rawValue]))
        let back = NoteConverter.htmlToAttributedString(NoteConverter.attributedStringToHtml(s))
        XCTAssertTrue(traits(back, at: range(of: "Bold", in: back).location).contains(.bold))
        XCTAssertFalse(traits(back, at: range(of: " and ", in: back).location).contains(.bold))
        XCTAssertTrue(traits(back, at: range(of: "Italic", in: back).location).contains(.italic))
        XCTAssertEqual(back.attribute(.underlineStyle, at: range(of: "Under", in: back).location, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
    }

    /// 严格文本保真：一次往返后文本必须与原文完全一致（不能多出/丢失换行）。
    func testRoundTripExactTextWithLineBreaks() {
        let original = "line1\nline2\n\nline4"
        let s = NSAttributedString(string: original, attributes: [.font: font()])
        let back = NoteConverter.htmlToAttributedString(NoteConverter.attributedStringToHtml(s))
        XCTAssertEqual(back.string, original)
    }

    /// 多次同步往返（上传->拉取->上传…）后文本长度应稳定，不能逐次累积换行。
    func testRepeatedRoundTripIsStable() {
        var cur: NSAttributedString = NSAttributedString(string: "hello\nworld", attributes: [.font: font()])
        var lengths: [Int] = []
        for _ in 0..<3 {
            cur = NoteConverter.htmlToAttributedString(NoteConverter.attributedStringToHtml(cur))
            lengths.append(cur.length)
        }
        XCTAssertEqual(Set(lengths).count, 1, "多次往返长度变化: \(lengths)")
        XCTAssertEqual(cur.string, "hello\nworld")
    }

    func testRoundTripTodoPrefixes() {
        let original = "☐ Buy milk\n☑ Done item\n• bullet"
        let s = NSMutableAttributedString(string: original, attributes: [.font: font()])
        // 已完成 todo 行：删除线（与 TextEditorProxy.toggleTodoAt 一致）
        let doneRange = (original as NSString).range(of: "☑ Done item")
        s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: doneRange)
        let html = NoteConverter.attributedStringToHtml(s)
        XCTAssertTrue(html.contains("☐ Buy milk"))
        XCTAssertTrue(html.contains("<s>☑ Done item</s>"), html)
        let back = NoteConverter.htmlToAttributedString(html)
        XCTAssertEqual(back.string.trimmingCharacters(in: .newlines), original)
        let loc = range(of: "☑ Done item", in: back).location
        XCTAssertNotEqual(loc, NSNotFound)
        XCTAssertEqual(back.attribute(.strikethroughStyle, at: loc, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testRoundTripSpecialCharacters() {
        let original = "<script>alert('x')</script> & \"q\" 中文 😀"
        let s = NSAttributedString(string: original, attributes: [.font: font()])
        let back = NoteConverter.htmlToAttributedString(NoteConverter.attributedStringToHtml(s))
        XCTAssertEqual(back.string.trimmingCharacters(in: .newlines), original)
    }

    func testCustomColorExportedAsHex() {
        let s = NSAttributedString(string: "red", attributes: [.font: font(), .foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)])
        XCTAssertTrue(NoteConverter.attributedStringToHtml(s).contains("color:#FF0000;"))
        let d = NSAttributedString(string: "def", attributes: [.font: font(), .foregroundColor: NSColor.textColor])
        XCTAssertEqual(NoteConverter.attributedStringToHtml(d), "<div>def</div>", "默认文字色不应写入 HTML")
    }

    // MARK: Plain text helpers

    func testPlainTextToHtml() {
        XCTAssertEqual(NoteConverter.plainTextToHtml("a<b\nc"), "<div>a&lt;b<br/>c</div>")
    }

    func testExtractPlainText() {
        XCTAssertEqual(NoteConverter.extractPlainText(from: "<div>Hello<br>World</div><p>P &amp; Q &lt;x&gt;</p>"),
                       "Hello\nWorld\nP & Q <x>")
        XCTAssertEqual(NoteConverter.extractPlainText(from: ""), "")
    }

    /// Outlook/Graph 返回的 HTML 常含数字实体（&#39; &#160;）。
    func testExtractPlainTextNumericEntities() {
        XCTAssertEqual(NoteConverter.extractPlainText(from: "<div>it&#39;s&#160;ok</div>"), "it's ok")
    }

    // MARK: Boundaries

    func testVeryLongTextRoundTrip() {
        let line = String(repeating: "长文本ABC", count: 100) // 600 chars
        let original = Array(repeating: line, count: 100).joined(separator: "\n") // ~60k chars
        let s = NSAttributedString(string: original, attributes: [.font: font()])
        let start = Date()
        let html = NoteConverter.attributedStringToHtml(s)
        let back = NoteConverter.htmlToAttributedString(html)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(back.string.trimmingCharacters(in: .newlines), original)
        XCTAssertLessThan(elapsed, 5.0, "6 万字往返耗时 \(elapsed)s")
        print("QA_METRIC longTextRoundTrip chars=\(original.count) seconds=\(elapsed)")
    }
}

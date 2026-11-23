import XCTest
import AppKit

/// ⌘V / 系统粘贴：通过生产代码把剪贴板写入 NSTextView（无真实窗口键焦点依赖的逻辑覆盖）。
@MainActor
final class NoteEditorPasteTests: XCTestCase {

    private func makeEditor(_ text: String = "") -> (TextEditorProxy, NSTextView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.isEditable = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.string = text
        let proxy = TextEditorProxy()
        proxy.textView = textView
        return (proxy, textView)
    }

    /// Snapshot and restore EVERY pasteboard item and representation so running unit tests never wipes
    /// images, files, or rich text from the developer's system clipboard.
    private func withPreservedPasteboard(_ body: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard.general
        let savedItems: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
        defer {
            pasteboard.clearContents()
            if !savedItems.isEmpty {
                let restored: [NSPasteboardItem] = savedItems.compactMap { reps in
                    guard !reps.isEmpty else { return nil }
                    let item = NSPasteboardItem()
                    for (type, data) in reps {
                        item.setData(data, forType: type)
                    }
                    return item
                }
                if !restored.isEmpty {
                    pasteboard.writeObjects(restored)
                }
            }
        }
        body(pasteboard)
    }

    private func withPasteboardString(_ value: String, _ body: () -> Void) {
        withPreservedPasteboard { pasteboard in
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString(value, forType: .string))
            body()
        }
    }

    func testFindNoteTextViewDescendsIntoScrollView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let scrollView = NSScrollView(frame: container.bounds)
        let textView = NSTextView(frame: container.bounds)
        scrollView.documentView = textView
        container.addSubview(scrollView)
        XCTAssertTrue(NotePasteSupport.findNoteTextView(in: container) === textView)
    }

    func testProxyPasteInsertsPlainTextAtCaret() {
        let (proxy, textView) = makeEditor("Hello")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        withPasteboardString(" World") {
            proxy.paste()
        }
        XCTAssertEqual(textView.string, "Hello World")
    }

    func testPasteInsertsWithoutWindowOrFirstResponder() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 24, width: 300, height: 200))
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = true
        textView.isRichText = true
        textView.string = "Hi"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        scrollView.documentView = textView
        container.addSubview(scrollView)

        XCTAssertTrue(NotePasteSupport.findNoteTextView(in: container) === textView)

        withPasteboardString(" there") {
            NotePasteSupport.findNoteTextView(in: container)?.paste(nil)
        }
        XCTAssertEqual(textView.string, "Hi there")
    }

    func testPasteInsertsRichTextAttributes() {
        let (_, textView) = makeEditor("A")
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        let rich = NSMutableAttributedString(string: "Z")
        rich.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: 1)
        )
        withPreservedPasteboard { pasteboard in
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([rich]))
            textView.paste(nil)
        }
        XCTAssertEqual(textView.string, "AZ")
        let underline = textView.textStorage?.attribute(
            .underlineStyle,
            at: 1,
            effectiveRange: nil
        ) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
    }

    func testColorSwatchAccessibilityIdentifiersAreUnique() {
        let ids = NoteColor.allCases.map { "note-color-\($0.rawValue)" }
        XCTAssertEqual(Set(ids).count, NoteColor.allCases.count)
        XCTAssertEqual(ids.count, 7)
        for color in NoteColor.allCases {
            XCTAssertFalse(color.displayName.isEmpty, "\(color.rawValue) 缺少显示名")
        }
    }
}

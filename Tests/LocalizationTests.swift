import XCTest

/// 模块 5：Localizable.xcstrings 完整性（en / zh-Hans）
final class LocalizationTests: XCTestCase {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadCatalog() throws -> [String: Any] {
        let url = projectRoot.appendingPathComponent("StickyNotes/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["strings"] as? [String: Any])
    }

    private func value(_ entry: Any?, lang: String) -> (state: String?, value: String?) {
        guard let e = entry as? [String: Any],
              let locs = e["localizations"] as? [String: Any],
              let l = locs[lang] as? [String: Any],
              let su = l["stringUnit"] as? [String: Any] else { return (nil, nil) }
        return (su["state"] as? String, su["value"] as? String)
    }

    func testEveryKeyHasTranslatedEnAndZhHans() throws {
        let strings = try loadCatalog()
        XCTAssertFalse(strings.isEmpty)
        var problems: [String] = []
        for (key, entry) in strings {
            for lang in ["en", "zh-Hans"] {
                let v = value(entry, lang: lang)
                if v.state != "translated" || (v.value ?? "").isEmpty {
                    problems.append("\(lang): \(key) state=\(v.state ?? "nil")")
                }
            }
        }
        print("QA_METRIC xcstringsKeys=\(strings.count)")
        XCTAssertEqual(problems, [], "缺失/未翻译条目: \(problems)")
    }

    func testFormatSpecifiersMatchBetweenLanguages() throws {
        let strings = try loadCatalog()
        let re = try NSRegularExpression(pattern: "%(\\d+\\$)?(lld|ld|@|d|f|\\.\\d+f)")
        func specs(_ s: String) -> [String] {
            re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }.sorted()
        }
        var bad: [String] = []
        for (key, entry) in strings {
            let en = value(entry, lang: "en").value ?? ""
            let zh = value(entry, lang: "zh-Hans").value ?? ""
            if specs(en) != specs(zh) { bad.append(key) }
        }
        XCTAssertEqual(bad, [], "中英文占位符不一致: \(bad)")
    }

    /// 源码中所有 String(localized: "...") 字面量都必须在 xcstrings 中存在。
    func testAllSourceLiteralsPresentInCatalog() throws {
        let strings = try loadCatalog()
        let srcDir = projectRoot.appendingPathComponent("StickyNotes")
        let re = try NSRegularExpression(pattern: #"String\(localized:\s*"((?:[^"\\]|\\.)*)""#)
        var missing: Set<String> = []
        var total = 0
        let en = FileManager.default.enumerator(at: srcDir, includingPropertiesForKeys: nil)!
        for case let url as URL in en where url.pathExtension == "swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            for m in re.matches(in: src, range: NSRange(src.startIndex..., in: src)) {
                var key = (src as NSString).substring(with: m.range(at: 1))
                total += 1
                // Swift interpolation "\(x)" becomes "%@" in the catalog key
                key = key.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "%@", options: .regularExpression)
                if strings[key] == nil { missing.insert("\(url.lastPathComponent): \(key)") }
            }
        }
        print("QA_METRIC sourceLocalizedLiterals=\(total)")
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(missing.sorted(), [], "源码中未收录到 xcstrings 的文案: \(missing.sorted())")
    }

    func testListAndNoteWindowTitlesDiffer() throws {
        let strings = try loadCatalog()
        let listZh = value(strings["Notes List"], lang: "zh-Hans").value
        let noteZh = value(strings["Note"], lang: "zh-Hans").value
        let listEn = value(strings["Notes List"], lang: "en").value
        let noteEn = value(strings["Note"], lang: "en").value
        XCTAssertEqual(listZh, "便签列表")
        XCTAssertEqual(noteZh, "便签")
        XCTAssertEqual(listEn, "Notes List")
        XCTAssertEqual(noteEn, "Note")
        XCTAssertNotEqual(listZh, noteZh, "中文下列表窗与便签窗标题不能都叫「便签」")
        XCTAssertNotEqual(listEn, noteEn)
        XCTAssertEqual(value(strings["Note Options"], lang: "zh-Hans").value, "便签选项")
        XCTAssertEqual(value(strings["Delete Note"], lang: "zh-Hans").value, "删除便签")
        XCTAssertEqual(value(strings["Paste"], lang: "zh-Hans").value, "粘贴")
    }
}

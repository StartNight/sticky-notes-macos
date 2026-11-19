import XCTest
import SwiftUI
import AppKit

/// 模块 2：颜色与外观 + 官方便笺七色枚举映射
final class NoteColorTests: XCTestCase {

    func testSevenColorsDefined() {
        // 需求写“6 种主题色”，代码实际定义 7 种（含 gray）
        XCTAssertEqual(NoteColor.allCases.map(\.rawValue),
                       ["yellow", "green", "pink", "purple", "blue", "gray", "charcoal"])
    }

    func testRawValueCodableRoundTrip() throws {
        for c in NoteColor.allCases {
            let data = try JSONEncoder().encode(c)
            XCTAssertEqual(try JSONDecoder().decode(NoteColor.self, from: data), c)
            XCTAssertEqual(NoteColor(rawValue: c.rawValue), c)
        }
    }

    func testDisplayNamesNonEmpty() {
        for c in NoteColor.allCases { XCTAssertFalse(c.displayName.isEmpty) }
    }

    func testHexToNSColorComponents() throws {
        let c = try XCTUnwrap(NSColor(hex: 0xFFF9B1).usingColorSpace(.sRGB))
        XCTAssertEqual(Int(round(c.redComponent * 255)), 0xFF)
        XCTAssertEqual(Int(round(c.greenComponent * 255)), 0xF9)
        XCTAssertEqual(Int(round(c.blueComponent * 255)), 0xB1)
        let g = try XCTUnwrap(NSColor(hex: 0x3B5E78, alpha: 0.5).usingColorSpace(.sRGB))
        XCTAssertEqual(Int(round(g.redComponent * 255)), 0x3B)
        XCTAssertEqual(Int(round(g.greenComponent * 255)), 0x5E)
        XCTAssertEqual(Int(round(g.blueComponent * 255)), 0x78)
        XCTAssertEqual(g.alphaComponent, 0.5, accuracy: 0.001)
    }

    func testLightAndDarkBackgroundsDiffer() {
        for c in NoteColor.allCases {
            let light = NSColor(c.backgroundColor(for: .light)).usingColorSpace(.sRGB)
            let dark = NSColor(c.backgroundColor(for: .dark)).usingColorSpace(.sRGB)
            XCTAssertNotNil(light); XCTAssertNotNil(dark)
            XCTAssertNotEqual(light, dark, "\(c) 深浅色背景应不同")
        }
    }

    // MARK: Official Sticky Notes color codes (upload <-> local <-> download)

    func testOutlookCodeEncodeForNativeColors() {
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .yellow), 0)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .green), 1)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .pink), 2)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .purple), 3)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .blue), 4)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .gray), 5)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .charcoal), 6)
    }

    func testOutlookCodeDecode() {
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 0), .yellow)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 1), .green)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 2), .pink)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 3), .purple)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 4), .blue)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 5), .gray)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 6), .charcoal)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: -1), .yellow, "未知值回退黄色")
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 99), .yellow, "未知值回退黄色")
    }

    /// 全部 7 种官方颜色经上传编码再下载解码，必须保持原色。
    func testOutlookCodeRoundTripAllColors() {
        let expected: [(NoteColor, Int)] = [
            (.yellow, 0), (.green, 1), (.pink, 2), (.purple, 3),
            (.blue, 4), (.gray, 5), (.charcoal, 6)
        ]
        XCTAssertEqual(NoteColor.allCases, expected.map(\.0))
        var lossy: [String] = []
        for (color, code) in expected {
            XCTAssertEqual(NoteConverter.outlookColorCode(for: color), code, "\(color.rawValue) 上传编码")
            XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: code), color, "\(code) 下载解码")
            let back = NoteConverter.noteColor(fromOutlookCode: NoteConverter.outlookColorCode(for: color))
            if back != color { lossy.append("\(color.rawValue)->\(back.rawValue)") }
        }
        XCTAssertEqual(lossy, [], "官方色板往返后颜色丢失: \(lossy)")
    }

    func testLegacyOrangePersistedValueMapsToCharcoal() throws {
        XCTAssertEqual(NoteColor.fromPersisted("orange"), .charcoal)
        let data = try JSONEncoder().encode("orange")
        XCTAssertEqual(try JSONDecoder().decode(NoteColor.self, from: data), .charcoal)
    }

    func testWebNoteJSONSetsOfficialColorAndPreservesDocument() throws {
        let existing = """
        {"schemaVersion":"beta","document":{"type":"document"},"color":0,"#type.color":"Int32"}
        """
        let updated = NoteConverter.webNoteJSON(setting: .charcoal, existing: existing)
        let data = try XCTUnwrap(updated.data(using: .utf8))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["color"] as? Int, 6)
        XCTAssertEqual(obj["#type.color"] as? String, "Int32")
        let document = try XCTUnwrap(obj["document"] as? [String: Any])
        XCTAssertEqual(document["type"] as? String, "document")
        XCTAssertEqual(NoteConverter.noteColor(fromWebNoteJSON: updated), .charcoal)
    }

    func testExtractPrefersWebNoteJSONColorOverPidLid() {
        let props: [[String: Any]] = [
            ["id": NoteConverter.pidLidNoteColorPropertyId, "value": "0"],
            ["id": NoteConverter.webNoteJSONPropertyId, "value": "{\"color\":6,\"#type.color\":\"Int32\"}"]
        ]
        let extracted = NoteConverter.extractNoteColor(fromExtendedProperties: props)
        XCTAssertEqual(extracted.color, .charcoal)
        XCTAssertEqual(NoteConverter.noteColor(fromWebNoteJSON: extracted.webNoteJSON ?? ""), .charcoal)
    }

    func testGraphColorExtendedPropertiesIncludeWebNotePayload() throws {
        for (color, code) in [
            (NoteColor.yellow, 0), (.green, 1), (.pink, 2), (.purple, 3),
            (.blue, 4), (.gray, 5), (.charcoal, 6)
        ] {
            let props = NoteConverter.graphColorExtendedProperties(for: color, existingWebNoteJSON: nil)
            XCTAssertEqual(props.count, 3)
            XCTAssertEqual(props[0]["id"] as? String, NoteConverter.pidLidNoteColorPropertyId)
            XCTAssertEqual(props[0]["value"] as? String, "\(NoteConverter.pidLidNoteColorCode(for: color))", "\(color.rawValue) PidLid")
            XCTAssertEqual(props[1]["id"] as? String, NoteConverter.pidTagIconIndexPropertyId)
            XCTAssertEqual(props[1]["value"] as? String, "\(NoteConverter.pidTagIconIndex(for: color))", "\(color.rawValue) IconIndex")
            XCTAssertEqual(props[2]["id"] as? String, NoteConverter.webNoteJSONPropertyId)
            let json = try XCTUnwrap(props[2]["value"] as? String)
            XCTAssertEqual(NoteConverter.noteColor(fromWebNoteJSON: json), color)
            let data = try XCTUnwrap(json.data(using: .utf8))
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(obj["color"] as? Int, code, "\(color.rawValue) 的 _Note.color")
        }
    }

    func testPidTagIconIndexMatchesMSOxonoteFormula() {
        XCTAssertEqual(NoteConverter.pidTagIconIndex(for: .blue), 0x300)     // 768
        XCTAssertEqual(NoteConverter.pidTagIconIndex(for: .green), 0x301)    // 769
        XCTAssertEqual(NoteConverter.pidTagIconIndex(for: .pink), 0x302)     // 770
        XCTAssertEqual(NoteConverter.pidTagIconIndex(for: .yellow), 0x303)   // 771
        XCTAssertEqual(NoteConverter.pidTagIconIndex(for: .gray), 0x304)     // 772
        XCTAssertEqual(NoteConverter.pidTagIconIndex(for: .purple), 0x304)   // 772
        XCTAssertEqual(NoteConverter.pidTagIconIndex(for: .charcoal), 0x304) // 772
    }

    func testIsIncompleteWebNoteJSONDetection() {
        XCTAssertFalse(NoteConverter.isIncompleteWebNoteJSON(nil))
        XCTAssertFalse(NoteConverter.isIncompleteWebNoteJSON(""))
        XCTAssertFalse(NoteConverter.isIncompleteWebNoteJSON("invalid json"))

        // Old 84-byte JSON missing document:
        let legacy = "{\"schemaVersion\":\"beta\",\"#type.color\":\"Int32\",\"color\":3,\"color@Is.Queryable\":\"True\"}"
        XCTAssertTrue(NoteConverter.isIncompleteWebNoteJSON(legacy))
        XCTAssertTrue(NoteConverter.isLegacyMacAuthoredIncompleteNoteJSON(legacy))

        // Complete JSON with document:
        let complete = "{\"schemaVersion\":\"beta\",\"color\":3,\"document\":{\"type\":\"document\",\"blocks\":[{\"type\":\"paragraph\"}]}}"
        XCTAssertFalse(NoteConverter.isIncompleteWebNoteJSON(complete))
        XCTAssertTrue(NoteConverter.hasCompleteSubstrateDocument(complete))
        XCTAssertFalse(NoteConverter.isLegacyMacAuthoredIncompleteNoteJSON(complete))
        XCTAssertFalse(NoteConverter.isLegacyMacAuthoredIncompleteNoteJSON(nil))
        XCTAssertFalse(NoteConverter.isLegacyMacAuthoredIncompleteNoteJSON("{\"color\":1}"))
    }

    func testOfficialLightHexMatchesWindowsStickyNotes() {
        let expected: [(NoteColor, UInt)] = [
            (.yellow, 0xFFF4B9), (.green, 0xBEEDB6), (.pink, 0xFFD7EA),
            (.purple, 0xECDAFF), (.blue, 0xD7EEFE), (.gray, 0xE9E9E9),
            (.charcoal, 0x565656)
        ]
        for (color, hex) in expected {
            XCTAssertEqual(color.officialLightHex, hex, "\(color.rawValue) body hex")
        }
        XCTAssertEqual(NoteColor.yellow.officialToolbarHex, 0xFFEC90)
        XCTAssertEqual(NoteColor.charcoal.officialToolbarHex, 0x4E4E4E)
    }

    func testPidLidClassicMappingDiffersFromWebForYellowAndBlue() {
        XCTAssertEqual(NoteConverter.webNoteColorCode(for: .yellow), 0)
        XCTAssertEqual(NoteConverter.pidLidNoteColorCode(for: .yellow), 3)
        XCTAssertEqual(NoteConverter.webNoteColorCode(for: .blue), 4)
        XCTAssertEqual(NoteConverter.pidLidNoteColorCode(for: .blue), 0)
        XCTAssertEqual(NoteConverter.pidLidNoteColorCode(for: .green), 1)
        XCTAssertEqual(NoteConverter.pidLidNoteColorCode(for: .pink), 2)
        XCTAssertEqual(NoteConverter.pidLidNoteColorCode(for: .gray), 4)
        XCTAssertEqual(NoteConverter.pidLidNoteColorCode(for: .purple), 4)
        XCTAssertEqual(NoteConverter.pidLidNoteColorCode(for: .charcoal), 4)
        XCTAssertEqual(NoteConverter.noteColor(fromPidLidCode: 0), .blue)
        XCTAssertEqual(NoteConverter.noteColor(fromPidLidCode: 3), .yellow)
        XCTAssertEqual(NoteConverter.noteColor(fromPidLidCode: 4), .gray)
        XCTAssertEqual(NoteConverter.noteColor(fromWebCode: 0), .yellow)
        XCTAssertEqual(NoteConverter.noteColor(fromWebCode: 4), .blue)
    }

    func testExtractFallsBackToClassicPidLidWhenWebNoteMissing() {
        let yellowClassic: [[String: Any]] = [
            ["id": NoteConverter.pidLidNoteColorPropertyId, "value": "3"]
        ]
        XCTAssertEqual(NoteConverter.extractNoteColor(fromExtendedProperties: yellowClassic).color, .yellow)

        let blueClassic: [[String: Any]] = [
            ["id": NoteConverter.pidLidNoteColorPropertyId, "value": "0"]
        ]
        XCTAssertEqual(NoteConverter.extractNoteColor(fromExtendedProperties: blueClassic).color, .blue)
    }

    // MARK: - 颜色同步诊断日志（默认关闭，只记打码 id 与颜色码）

    func testDiagnosticsTagIsAStableShortHashAndNeverTheRawID() {
        XCTAssertEqual(ColorDiagnostics.tag("abc"), "ba7816", "SHA-256(\"abc\") 的前 3 字节")
        XCTAssertEqual(ColorDiagnostics.tag(nil), "-")
        let id = "AAMkAGE1-secret-graph-object-id="
        let tag = ColorDiagnostics.tag(id)
        XCTAssertEqual(tag.count, 6)
        XCTAssertFalse(id.contains(tag) || tag.contains("secret"))
    }

    func testRawColorCodesReportWhichFieldDecidedTheColour() {
        let lid: [String: Any] = ["id": NoteConverter.pidLidNoteColorPropertyId, "value": "3"]
        let web: [String: Any] = ["id": NoteConverter.webNoteJSONPropertyId, "value": "{\"color\":6}"]
        let both = NoteConverter.rawColorCodes(fromExtendedProperties: [lid, web])
        XCTAssertEqual(both.webCode, 6); XCTAssertEqual(both.lidCode, 3); XCTAssertEqual(both.source, "_Note")
        let onlyLid = NoteConverter.rawColorCodes(fromExtendedProperties: [lid])
        XCTAssertNil(onlyLid.webCode); XCTAssertEqual(onlyLid.lidCode, 3); XCTAssertEqual(onlyLid.source, "0x8B00")
        let none = NoteConverter.rawColorCodes(fromExtendedProperties: [])
        XCTAssertNil(none.webCode); XCTAssertNil(none.lidCode); XCTAssertEqual(none.source, "default(yellow)")
        // 与真实解析一致：诊断只是旁路，结论必须相同
        XCTAssertEqual(NoteConverter.extractNoteColor(fromExtendedProperties: [lid, web]).color, .charcoal)
        XCTAssertEqual(NoteConverter.extractNoteColor(fromExtendedProperties: [lid]).color, .yellow)
    }

    func testDiagnosticsAreOffUnlessTheDefaultsKeyIsSet() {
        XCTAssertFalse(ColorDiagnostics.enabled, "未设置 ColorDiagnosticsEnabled 时不得输出任何诊断")
    }

    func testWebNoteJSONBuildsSubstrateDocumentWhenMissing() throws {
        let localID = UUID()
        let jsonStr = NoteConverter.webNoteJSON(
            setting: .purple,
            existing: nil,
            plainText: "line 1\nline 2",
            localID: localID
        )
        let data = try XCTUnwrap(jsonStr.data(using: .utf8))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["schemaVersion"] as? String, "beta")
        XCTAssertEqual(obj["color"] as? Int, 3)
        XCTAssertEqual(obj["#type.color"] as? String, "Int32")
        XCTAssertEqual(obj["color@Is.Queryable"] as? String, "True")
        XCTAssertEqual(obj["createdWithLocalId"] as? String, localID.uuidString.lowercased())
        XCTAssertEqual(obj["createdByApp"] as? String, "StickyNotes")
        XCTAssertNotNil(obj["documentModifiedAt"] as? String)
        let document = try XCTUnwrap(obj["document"] as? [String: Any])
        XCTAssertEqual(document["type"] as? String, "document")
        let blocks = try XCTUnwrap(document["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        let firstContent = try XCTUnwrap(blocks[0]["content"] as? [[String: Any]])
        XCTAssertEqual(firstContent.first?["text"] as? String, "line 1")
    }

}

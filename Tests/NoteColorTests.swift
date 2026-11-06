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
            XCTAssertEqual(props.count, 2)
            XCTAssertEqual(props[0]["id"] as? String, NoteConverter.pidLidNoteColorPropertyId)
            XCTAssertEqual(props[0]["value"] as? String, "\(NoteConverter.pidLidNoteColorCode(for: color))", "\(color.rawValue) PidLid")
            XCTAssertEqual(props[1]["id"] as? String, NoteConverter.webNoteJSONPropertyId)
            let json = try XCTUnwrap(props[1]["value"] as? String)
            XCTAssertEqual(NoteConverter.noteColor(fromWebNoteJSON: json), color)
            let data = try XCTUnwrap(json.data(using: .utf8))
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(obj["color"] as? Int, code, "\(color.rawValue) 的 _Note.color")
        }
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

}

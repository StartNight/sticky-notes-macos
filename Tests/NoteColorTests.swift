import XCTest
import SwiftUI
import AppKit

/// 模块 2：颜色与外观 + Outlook PidLidNoteColor (0x8b00) 映射
final class NoteColorTests: XCTestCase {

    func testSevenColorsDefined() {
        // 需求写“6 种主题色”，代码实际定义 7 种（含 gray）
        XCTAssertEqual(NoteColor.allCases.map(\.rawValue),
                       ["yellow", "green", "blue", "purple", "pink", "orange", "gray"])
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

    // MARK: Outlook 0x8b00 (PidLidNoteColor) integer codes

    func testOutlookCodeEncodeForNativeColors() {
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .blue), 0)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .green), 1)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .pink), 2)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .yellow), 3)
        XCTAssertEqual(NoteConverter.outlookColorCode(for: .gray), 4)
    }

    func testOutlookCodeDecode() {
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 0), .blue)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 1), .green)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 2), .pink)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 3), .yellow)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 4), .gray)
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: -1), .yellow, "未知值回退黄色")
        XCTAssertEqual(NoteConverter.noteColor(fromOutlookCode: 99), .yellow, "未知值回退黄色")
    }

    /// 全部 7 种本地颜色经 0x8b00 编码再解码，是否保持原色。
    /// purple / orange 在 Outlook 无对应值，预期此用例暴露有损映射。
    func testOutlookCodeRoundTripAllColors() {
        var lossy: [String] = []
        for c in NoteColor.allCases {
            let back = NoteConverter.noteColor(fromOutlookCode: NoteConverter.outlookColorCode(for: c))
            if back != c { lossy.append("\(c.rawValue)->\(back.rawValue)") }
        }
        XCTAssertEqual(lossy, [], "经 Outlook 0x8b00 往返后颜色丢失: \(lossy)")
    }
}

import SwiftUI

/// Official Microsoft Sticky Notes palette, in the same picker order as
/// the Windows / web apps: Yellow, Green, Pink, Purple, Blue, Gray, Charcoal.
enum NoteColor: String, CaseIterable, Codable {
    case yellow, green, pink, purple, blue, gray, charcoal

    /// Maps persisted raw values, including the retired local `orange` case.
    static func fromPersisted(_ rawValue: String) -> NoteColor {
        if rawValue == "orange" { return .charcoal }
        return NoteColor(rawValue: rawValue) ?? .yellow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = NoteColor.fromPersisted(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: - Official Microsoft Sticky Notes swatches
    // Body / header colors sampled from the official Windows Sticky Notes
    // app (yellow body #FFF4B9). Outlook on the web renders the same seven named
    // colors; we keep picker order 黄/绿/粉/紫/蓝/灰/炭笔.

    /// Note body hex in light mode (sRGB), matching the official Windows app.
    var officialLightHex: UInt { colorSet.light }
    /// Note header/toolbar hex in light mode (sRGB).
    var officialToolbarHex: UInt { colorSet.toolbarLight }

    private var colorSet: (light: UInt, dark: UInt, toolbarLight: UInt, toolbarDark: UInt) {
        switch self {
        case .yellow:   (0xFFF4B9, 0x6B5F1A, 0xFFEC90, 0x5A4F12)
        case .green:    (0xBEEDB6, 0x2F5B32, 0xA8E0A0, 0x244A28)
        case .pink:     (0xFFD7EA, 0x6B3040, 0xFFC9E4, 0x5A2734)
        case .purple:   (0xECDAFF, 0x4E3266, 0xE0C8FA, 0x3F2754)
        case .blue:     (0xD7EEFE, 0x2B4F66, 0xC5E4FA, 0x223F52)
        case .gray:     (0xE9E9E9, 0x4A4A4A, 0xD0D0D0, 0x3A3A3A)
        case .charcoal: (0x565656, 0x2A2A2A, 0x4E4E4E, 0x1F1F1F)
        }
    }

    var background: Color { Color(hex: colorSet.light) }
    var darkBackground: Color { Color(hex: colorSet.dark) }
    var toolbar: Color { Color(hex: colorSet.toolbarLight) }
    var darkToolbar: Color { Color(hex: colorSet.toolbarDark) }

    var displayName: String {
        switch self {
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .pink: return String(localized: "Pink")
        case .purple: return String(localized: "Purple")
        case .blue: return String(localized: "Blue")
        case .gray: return String(localized: "Gray")
        case .charcoal: return String(localized: "Charcoal")
        }
    }

    func backgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkBackground : background
    }

    func toolbarColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkToolbar : toolbar
    }
}

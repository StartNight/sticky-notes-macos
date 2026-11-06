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

    // MARK: - Color Data (official pastel swatches; charcoal is dark)

    private var colorSet: (light: UInt, dark: UInt, toolbarLight: UInt, toolbarDark: UInt) {
        switch self {
        case .yellow:   (0xFFF2AB, 0x7B7533, 0xF2E685, 0x6B6528)
        case .green:    (0xDFF6DD, 0x3D6B3D, 0xB7E0B4, 0x335C33)
        case .pink:     (0xFFD9D9, 0x7B4058, 0xF0B8C4, 0x6B354B)
        case .purple:   (0xE4D5F5, 0x5B4670, 0xC9B6E3, 0x4D3A5E)
        case .blue:     (0xD9E8FF, 0x3B5E78, 0xB3CFF0, 0x314F65)
        case .gray:     (0xF0F0F0, 0x555555, 0xD8D8D8, 0x474747)
        case .charcoal: (0x3B3B3B, 0x1F1F1F, 0x4A4A4A, 0x2A2A2A)
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

    func listCardColor(for colorScheme: ColorScheme) -> Color {
        backgroundColor(for: colorScheme).opacity(0.85)
    }
}

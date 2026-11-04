import SwiftUI

struct FormattingBar: View {
    let onBold: () -> Void
    let onItalic: () -> Void
    let onUnderline: () -> Void
    let onStrikethrough: () -> Void
    let onBulletList: () -> Void
    let onTodoList: () -> Void
    let onHiddenText: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            formatButton(icon: "bold", label: String(localized: "Bold"), tooltip: String(localized: "Bold (⌘B)"), action: onBold)
            formatButton(icon: "italic", label: String(localized: "Italic"), tooltip: String(localized: "Italic (⌘I)"), action: onItalic)
            formatButton(icon: "underline", label: String(localized: "Underline"), tooltip: String(localized: "Underline (⌘U)"), action: onUnderline)
            formatButton(icon: "strikethrough", label: String(localized: "Strikethrough"), tooltip: String(localized: "Strikethrough (⌘⇧X)"), action: onStrikethrough)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 3)

            formatButton(icon: "list.bullet", label: String(localized: "Bullet List"), tooltip: String(localized: "Bullet List (⌘⇧L)"), action: onBulletList)
            formatButton(icon: "checkmark.square", label: String(localized: "Todo List"), tooltip: String(localized: "Todo List"), action: onTodoList)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 3)

            formatButton(icon: "eye.slash", label: String(localized: "Hide Text"), tooltip: String(localized: "Hide/Reveal Text"), action: onHiddenText)
        }
    }

    private func formatButton(icon: String, label: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(tooltip)
    }
}

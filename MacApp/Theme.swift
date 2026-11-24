import AppKit
import SwiftUI

/// The app's look in one place, for light and dark. The review page uses the same values in app.css.
enum Theme {
    /// A color that follows the window's appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let background = adaptive(light: 0xFFFFFF, dark: 0x0E1014)
    static let surface = adaptive(light: 0xF4F5F8, dark: 0x171A20)
    static let raised = adaptive(light: 0xFFFFFF, dark: 0x1E222A)
    static let line = adaptive(light: 0xE3E6EC, dark: 0x282D37)
    static let text = adaptive(light: 0x12151B, dark: 0xECEEF2)
    static let secondary = adaptive(light: 0x5B6472, dark: 0xA3ABB8)
    static let accent = adaptive(light: 0x3563E9, dark: 0x6E97FF)
    static let good = adaptive(light: 0x16935F, dark: 0x45C48C)
    static let warn = adaptive(light: 0xB7791F, dark: 0xF0B429)
    static let gold = adaptive(light: 0xD98A0B, dark: 0xF5B83D)

    static let radius: CGFloat = 14
    static let controlRadius: CGFloat = 9
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
}

/// A card: a raised surface with a hairline border and a soft shadow in light mode.
struct Card: ViewModifier {
    var padding: CGFloat = 18
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 10, y: 3)
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(Card(padding: padding)) }
}

/// The main action of a screen: a filled rounded rectangle, never a capsule.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.surface.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.line))
    }
}

/// A thin progress bar in the app's own colors, the same whether or not the window is frontmost.
struct Meter: View {
    let value: Double  // 0...1
    var tint: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.line)
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint)
                    .frame(width: max(value > 0 ? 6 : 0, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(Theme.spring, value: value)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

extension Int {
    /// "1.2 GB", "340 MB": file sizes the way Finder shows them.
    var asFileSize: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) }
}

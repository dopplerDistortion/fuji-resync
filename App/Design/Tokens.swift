import SwiftUI

/// goksen.ing design tokens (https://goksen.ing/system). Dark only, square corners everywhere.
enum Token {
    static let background = Color(hex: 0x0B0B0C)
    static let foreground = Color(hex: 0xE6E3DE)   // "bone"
    static let card = Color(hex: 0x131314)
    static let muted = Color(hex: 0x1C1C1D)        // secondary / muted / accent
    static let mutedForeground = Color(hex: 0x8C8A86)
    static let signal = Color(hex: 0xFF3B30)       // faults and the primary action
    static let warn = Color(hex: 0xF5B400)
    static let mark = Color(hex: 0x5C5B58)         // crop marks, list marks
    static let border = Color(hex: 0x2A2A2B)
    static let input = Color(hex: 0x6B6A66)
    static let ring = Color(hex: 0xE6E3DE)
    static let ink = Color(hex: 0x0B0B0C)          // text on bone / signal

    static let gutter: CGFloat = 16
    static let rule: CGFloat = 1
}

enum Typeface {
    /// Martian Mono, width 112.5, weight 300 (instanced from the variable font).
    static func display(_ size: CGFloat) -> Font { .custom("MartianMono-Display", fixedSize: size) }
    /// Geist Mono, the body face. 16 px base.
    static func body(_ size: CGFloat = 16) -> Font { .custom("GeistMono-Regular", size: size, relativeTo: .body) }
    static func medium(_ size: CGFloat = 16) -> Font { .custom("GeistMono-Medium", size: size, relativeTo: .body) }
    /// 11 px uppercase, 0.08em tracking. Apply `.labelStyle()` for the tracking and case.
    static let label: Font = .custom("GeistMono-Medium", size: 11, relativeTo: .caption2)
    /// 13 px for box-drawing diagrams.
    static let diagram: Font = .custom("GeistMono-Regular", size: 13, relativeTo: .footnote)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension View {
    /// The system's 11 px uppercase label.
    func systemLabel(_ color: Color = Token.mutedForeground) -> some View {
        font(Typeface.label)
            .tracking(11 * 0.08)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

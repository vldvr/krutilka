import AppKit
import SwiftUI

/// Colour roles from replica/design/tokens.*.json. Contrast-checked (WCAG AA) in both appearances.
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    static let ring = dynamic(light: 0xF1F4F3, dark: 0x1D2326)
    static let hub = dynamic(light: 0xFFFFFF, dark: 0x283034)
    static let edge = dynamic(light: 0x7D8985, dark: 0x6F7D83)
    static let text = dynamic(light: 0x141A1C, dark: 0xEEF3F2)
    static let textMuted = dynamic(light: 0x56626A, dark: 0xA6B1B6)
    static let patina = dynamic(light: 0x0B7366, dark: 0x0E7D6F)
    static let patinaBright = dynamic(light: 0x0B7366, dark: 0x3FC2AE)
    static let danger = dynamic(light: 0xB8322A, dark: 0xFF7B70)

    /// The one accent. Follows the system accent if the person asked for that.
    static var accent: Color {
        Prefs.shared.accent == .system ? Color.accentColor : Color(nsColor: patina)
    }

    /// Accent used for thin marks (needle, rings) where a brighter tone reads better on dark glass.
    static var mark: Color {
        Prefs.shared.accent == .system ? Color.accentColor : Color(nsColor: patinaBright)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Font {
    /// Wide, engraved-looking type for format codes on the dial (SF Pro Expanded).
    static func dialCode(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if #available(macOS 13, *) {
            return .system(size: size, weight: weight).width(.expanded)
        }
        return .system(size: size, weight: weight)
    }
}

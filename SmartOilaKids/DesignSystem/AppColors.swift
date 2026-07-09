import SwiftUI
import UIKit

enum AppColors {
    private static func dynamic(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(
            uiColor: UIColor { traitCollection in
                traitCollection.userInterfaceStyle == .dark ? dark : light
            }
        )
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static let white = dynamic(rgb(255, 255, 255), rgb(26, 26, 30))
    static let black = dynamic(rgb(18, 18, 18), rgb(242, 242, 247))

    static let primaryPurple = dynamic(rgb(116, 61, 249), rgb(142, 108, 255))
    static let surfacePurple = dynamic(rgb(189, 163, 250), rgb(48, 37, 78))
    static let secondaryPurple = dynamic(rgb(168, 134, 251), rgb(74, 58, 114))

    static let accentGreen = dynamic(rgb(56, 227, 154), rgb(54, 208, 143))
    static let dangerRed = dynamic(rgb(255, 131, 131), rgb(255, 123, 123))

    static let neutral100 = dynamic(rgb(237, 237, 237), rgb(38, 38, 43))
    static let neutral200 = dynamic(rgb(226, 226, 226), rgb(47, 47, 53))
    static let neutral300 = dynamic(rgb(217, 217, 217), rgb(59, 59, 67))
    static let neutral500 = dynamic(rgb(0, 0, 0, 0.3), rgb(255, 255, 255, 0.28))
    static let neutral600 = dynamic(rgb(199, 199, 199), rgb(199, 199, 199))
    static let neutral700 = dynamic(rgb(134, 134, 134), rgb(134, 134, 134))
    static let neutral800 = dynamic(rgb(79, 79, 79), rgb(79, 79, 79))
    static let neutral900 = dynamic(rgb(66, 66, 66), rgb(66, 66, 66))

    static let textPrimary = dynamic(rgb(18, 18, 18), rgb(242, 242, 247))
    static let textSecondary = dynamic(rgb(0, 0, 0, 0.3), rgb(255, 255, 255, 0.55))

    // Use these on branded/dark surfaces where "white" should stay high-contrast in every theme.
    static let inverseTextPrimary = Color.white
    static let inverseTextSecondary = Color.white.opacity(0.82)
    static let inverseTextTertiary = Color.white.opacity(0.72)

    // MARK: - Bolajon360 (Yumshoq lavanda) redesign tokens
    // Additive: new screens consume these; legacy screens keep the tokens above until migrated.

    /// Full-bleed screen ground for setup + mandatory permission screens.
    static let bgLavender = dynamic(rgb(237, 233, 252), rgb(28, 25, 42))   // #EDE9FC
    /// Full-bleed screen ground for optional permission screens.
    static let bgPeach = dynamic(rgb(252, 234, 217), rgb(44, 34, 27))      // #FCEAD9
    /// Card / sheet surface floated on a tinted ground.
    static let cardWhite = dynamic(rgb(255, 255, 255), rgb(34, 31, 44))

    /// Primary call-to-action fill (pill buttons) across the new flows.
    static let ctaPurple = dynamic(rgb(124, 92, 252), rgb(142, 108, 255))  // #7C5CFC
    /// Glyph tint inside white icon badges on lavender screens.
    static let glyphPurple = dynamic(rgb(108, 76, 224), rgb(150, 120, 255)) // #6C4CE0
    /// Glyph tint inside white icon badges on peach screens.
    static let glyphCoral = dynamic(rgb(240, 96, 90), rgb(255, 122, 116))   // #F0605A
    /// Warm orange glyph tint for the optional-permission icons (peach hero steps).
    static let glyphOrange = dynamic(rgb(240, 133, 66), rgb(247, 148, 82))  // #F08542

    /// Success / connected state (avatar ring, "Yoqildi" pills).
    static let successGreen = dynamic(rgb(59, 201, 125), rgb(54, 208, 143)) // #3BC97D
    /// SOS / danger (confirm, disconnect).
    static let sosCoral = dynamic(rgb(240, 96, 90), rgb(255, 110, 104))     // #F0605A

    /// Purple-biased near-black ink for headings/body on tinted grounds.
    static let inkPrimary = dynamic(rgb(42, 37, 64), rgb(242, 242, 247))    // #2A2540
    static let inkSecondary = dynamic(rgb(91, 84, 112), rgb(190, 186, 205)) // #5B5470
    static let inkTertiary = dynamic(rgb(138, 131, 160), rgb(150, 145, 168))
    /// Hairline separators inside cards.
    static let hairline = dynamic(rgb(228, 222, 245), rgb(58, 54, 74))
    /// Neutral chip / inactive keypad key fill.
    static let chipNeutral = dynamic(rgb(240, 238, 249), rgb(46, 43, 58))

    // MARK: - Hero / sheet two-zone system (A1–A4 setup + B1–B11 permissions)
    // The redesigned flows paint a tinted HERO zone (top) behind a white bottom SHEET.
    // These endpoints drive the hero gradient; the sheet uses `cardWhite`.

    /// Standard lavender hero gradient (setup + mandatory permission steps).
    static let heroLavenderTop = dynamic(rgb(228, 220, 246), rgb(38, 33, 54))     // #E4DCF6
    static let heroLavenderBottom = dynamic(rgb(238, 233, 251), rgb(30, 27, 44))  // #EEE9FB
    /// Deeper lavender for the B1 intro hero.
    static let heroLavenderDeepTop = dynamic(rgb(213, 202, 242), rgb(46, 40, 70)) // #D5CAF2
    /// Peach hero gradient (optional permission steps B4–B10).
    static let heroPeachTop = dynamic(rgb(250, 230, 213), rgb(46, 36, 27))        // #FAE6D5
    static let heroPeachBottom = dynamic(rgb(253, 242, 233), rgb(36, 30, 24))     // #FDF2E9
    /// Soft white radial glow layered over the hero, centred behind the icon circle.
    static let heroGlow = dynamic(rgb(255, 255, 255, 0.55), rgb(255, 255, 255, 0.06))

    /// Neutral app background for the "C" list screens (Home, Tasks, Settings, status, PIN).
    /// Lighter and greyer than `bgLavender` to match the design board's near-white ground.
    static let screenBackground = dynamic(rgb(243, 242, 248), rgb(20, 18, 30))    // #F3F2F8

    /// Warm star / reward accent (task points, "N ⭐" chips).
    static let starAmber = dynamic(rgb(240, 176, 32), rgb(247, 191, 66))          // #F0B020
}

extension Color {
    /// Parses a hex color string like "#F0605A", "F0605A", or "#AARRGGBB".
    /// Returns nil for empty/malformed input so callers can fall back to a default.
    init?(hex: String?) {
        guard let raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        var value = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if value.lowercased().hasPrefix("0x") { value = String(value.dropFirst(2)) }
        guard value.count == 6 || value.count == 8 else { return nil }

        var int: UInt64 = 0
        guard Scanner(string: value).scanHexInt64(&int) else { return nil }

        let r, g, b, a: Double
        if value.count == 8 {
            a = Double((int & 0xFF00_0000) >> 24) / 255
            r = Double((int & 0x00FF_0000) >> 16) / 255
            g = Double((int & 0x0000_FF00) >> 8) / 255
            b = Double(int & 0x0000_00FF) / 255
        } else {
            a = 1
            r = Double((int & 0xFF0000) >> 16) / 255
            g = Double((int & 0x00FF00) >> 8) / 255
            b = Double(int & 0x0000FF) / 255
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

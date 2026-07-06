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
}

import SwiftUI

enum AppColors {
    static let white = Color.white
    static let black = Color(red: 0.07, green: 0.07, blue: 0.07) // #121212

    static let primaryPurple = Color(red: 0.45, green: 0.24, blue: 0.98) // #743DF9
    static let surfacePurple = Color(red: 0.74, green: 0.64, blue: 0.98) // #BDA3FA
    static let secondaryPurple = Color(red: 0.66, green: 0.53, blue: 0.98) // #A886FB

    static let accentGreen = Color(red: 0.22, green: 0.89, blue: 0.60) // #38E39A
    static let dangerRed = Color(red: 1.0, green: 0.51, blue: 0.51) // #FF8383

    static let neutral100 = Color(red: 0.93, green: 0.93, blue: 0.93) // #EDEDED
    static let neutral200 = Color(red: 0.89, green: 0.89, blue: 0.89) // #E2E2E2
    static let neutral300 = Color(red: 0.85, green: 0.85, blue: 0.85)
    static let neutral500 = Color.black.opacity(0.3)

    static let textPrimary = Color.black
    static let textSecondary = Color.black.opacity(0.3)
}

import SwiftUI
import UIKit

/// Native-only type system: everything renders in San Francisco (SF Pro), which the OS
/// automatically serves as SF Pro Display at large sizes and SF Pro Text at small ones.
/// The old bundled display fonts (Unbounded / Sora / Roboto) were dropped by request —
/// the legacy family helpers below now map straight to the system font so historical
/// call sites keep compiling and pick up SF automatically.
enum AppTypography {
    /// Bounded Dynamic Type: the fixed design point sizes scale with the user's text-size
    /// (accessibility) setting, capped so the pixel-tuned lavender layouts don't overflow at the
    /// largest sizes. At the DEFAULT text size `scaledValue(for:)` returns the size unchanged, so
    /// default-size fidelity is preserved exactly; only users who changed their text size see growth.
    private static let maxScale: CGFloat = 1.35

    private static func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let scaled = min(UIFontMetrics.default.scaledValue(for: size), size * maxScale)
        return .system(size: scaled, weight: weight)
    }

    // MARK: - Legacy family helpers (all SF now)

    static func unbounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Unbounded was an inherently heavy display face; keep its call sites from
        // going visually limp by bumping plain-regular requests to semibold.
        font(size, weight == .regular ? .semibold : weight)
    }

    static func sora(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(size, weight)
    }

    static func roboto(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(size, weight)
    }

    // MARK: - Bolajon360 role helpers
    // One place for the type scale so screens don't hardcode raw sizes.

    static func title(_ size: CGFloat = 22) -> Font { font(size, .bold) }
    static func heading(_ size: CGFloat = 18) -> Font { font(size, .semibold) }
    static func bodyText(_ size: CGFloat = 14) -> Font { font(size, .regular) }
    static func bodyStrong(_ size: CGFloat = 14) -> Font { font(size, .medium) }
    static func caption(_ size: CGFloat = 11) -> Font { font(size, .regular) }
    static func buttonLabel(_ size: CGFloat = 16) -> Font { font(size, .semibold) }
}

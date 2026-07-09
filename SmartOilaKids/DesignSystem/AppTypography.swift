import SwiftUI

/// Native-only type system: everything renders in San Francisco (SF Pro), which the OS
/// automatically serves as SF Pro Display at large sizes and SF Pro Text at small ones.
/// The old bundled display fonts (Unbounded / Sora / Roboto) were dropped by request —
/// the legacy family helpers below now map straight to the system font so historical
/// call sites keep compiling and pick up SF automatically.
enum AppTypography {
    // MARK: - Legacy family helpers (all SF now)

    static func unbounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Unbounded was an inherently heavy display face; keep its call sites from
        // going visually limp by bumping plain-regular requests to semibold.
        .system(size: size, weight: weight == .regular ? .semibold : weight)
    }

    static func sora(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func roboto(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: - Bolajon360 role helpers
    // One place for the type scale so screens don't hardcode raw sizes.

    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold) }
    static func heading(_ size: CGFloat = 18) -> Font { .system(size: size, weight: .semibold) }
    static func bodyText(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .regular) }
    static func bodyStrong(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .medium) }
    static func caption(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .regular) }
    static func buttonLabel(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .semibold) }
}

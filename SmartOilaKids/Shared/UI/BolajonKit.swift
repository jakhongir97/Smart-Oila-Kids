import SwiftUI
import UIKit

// Bolajon360 (Yumshoq lavanda) shared component kit.
// Additive design-system layer for the redesigned flows. Legacy screens keep their
// existing chrome (ChildChrome*) until each is migrated onto these components.

// MARK: - Metrics

enum BolajonMetrics {
    static let cardRadius: CGFloat = 22
    static let cardRadiusLarge: CGFloat = 28
    static let controlRadius: CGFloat = 16
    static let buttonHeight: CGFloat = 54
    static let screenPadding: CGFloat = 22
    static let cardPadding: CGFloat = 18
    static let stackSpacing: CGFloat = 16

    static let cardShadow = Color.black.opacity(0.06)
    static let cardShadowRadius: CGFloat = 18
    static let cardShadowY: CGFloat = 10
}

// MARK: - Shared literal tints

/// One-off literal colours used by a couple of components (not worth a full dynamic token).
enum BolajonPalette {
    /// Warm cream circle behind unselected language flags.
    static let cream = Color(.sRGB, red: 251 / 255, green: 242 / 255, blue: 230 / 255, opacity: 1)
}

// MARK: - Emoji render capability

/// Detects whether the current runtime can actually draw colour emoji. Some Simulator runtimes
/// ship without the Apple Color Emoji font and render a ".notdef" tofu box instead; detecting
/// that once lets emoji-based UI (the child avatar) fall back to an initial rather than a box.
/// Real devices always report `true`.
enum EmojiRenderCheck {
    static let systemRendersEmoji: Bool = {
        // Two distinct emoji render to different images on a device with the emoji font, but to
        // the same tofu box on a runtime that lacks it.
        guard let a = render("🙂"), let b = render("🚀") else { return true }
        return a != b
    }()

    private static func render(_ s: String) -> Data? {
        let size = CGSize(width: 22, height: 22)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            (s as NSString).draw(at: .zero, withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        return image.pngData()
    }
}

// MARK: - Screen intent

/// Signals the two-tone system: lavender for setup + mandatory, peach for optional.
enum ScreenIntent {
    case lavender
    case peach

    var ground: Color {
        switch self {
        case .lavender: return AppColors.bgLavender
        case .peach: return AppColors.bgPeach
        }
    }

    /// Glyph tint used inside white icon badges on this ground.
    var glyphTint: Color {
        switch self {
        case .lavender: return AppColors.glyphPurple
        case .peach: return AppColors.glyphOrange
        }
    }
}

// MARK: - Hero background (two-zone system)

/// The tinted, softly-glowing top zone that sits behind the white sheet on every setup /
/// permission step. Painted full-bleed (it extends under the navigation bar); the white sheet
/// masks its lower portion, leaving the tint peeking around the sheet's rounded top corners.
struct HeroBackground: View {
    var intent: ScreenIntent = .lavender
    /// The B1 intro uses a deeper lavender than the other lavender steps.
    var deep: Bool = false

    private var topColor: Color {
        switch intent {
        case .lavender: return deep ? AppColors.heroLavenderDeepTop : AppColors.heroLavenderTop
        case .peach: return AppColors.heroPeachTop
        }
    }

    private var bottomColor: Color {
        switch intent {
        case .lavender: return AppColors.heroLavenderBottom
        case .peach: return AppColors.heroPeachBottom
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [topColor, bottomColor],
                startPoint: .top,
                endPoint: .bottom
            )
            // Soft white glow + faint concentric rings emanating from behind the icon circle.
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width * 0.5, y: geo.size.height * 0.34)
                let base = min(geo.size.width, geo.size.height)
                ZStack {
                    RadialGradient(
                        colors: [AppColors.heroGlow, .clear],
                        center: .init(x: 0.5, y: 0.34),
                        startRadius: 0,
                        endRadius: base * 0.6
                    )
                    ForEach(1 ..< 4) { ring in
                        Circle()
                            .stroke(AppColors.heroGlow.opacity(0.25), lineWidth: 1)
                            .frame(width: base * (0.5 + CGFloat(ring) * 0.28),
                                   height: base * (0.5 + CGFloat(ring) * 0.28))
                            .position(center)
                    }
                }
            }
        }
    }
}

// MARK: - Sheet shape (top-rounded)

/// A rectangle with only its top two corners rounded — the white bottom sheet. iOS 15-safe
/// (predates `UnevenRoundedRectangle`).
struct TopRoundedRectangle: Shape {
    var radius: CGFloat = 38

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Hero + sheet scaffold

/// The core two-zone layout: a tinted hero (with the step icon) above a white bottom sheet
/// (title / body / content / CTA). Lives inside a NavigationStack destination — the native bar,
/// back button and progress capsules render on top of the hero, whose tint runs under them.
///
/// The white sheet is content-sized and anchored to the bottom; the tinted hero fills whatever
/// space remains above it, with its icon biased ~2:1 toward the bottom (so it hovers just above
/// the sheet, matching every board crop across short and tall sheets alike).
struct BolajonHeroSheet<Hero: View, SheetContent: View>: View {
    var intent: ScreenIntent = .lavender
    var deepHero: Bool = false
    var sheetRadius: CGFloat = 38
    /// Native inline navigation title (usually empty — these screens keep the title in-content).
    var title: String? = nil
    /// Hide the system back button (A4 success + B1 intro are terminal step roots).
    var blocksBack: Bool = false
    /// Progress capsules rendered in the bar's principal slot (nil on intro / summary).
    var progress: (current: Int, total: Int)? = nil
    var mandatoryCount: Int = 2
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var sheet: () -> SheetContent

    var body: some View {
        ZStack(alignment: .top) {
            HeroBackground(intent: intent, deep: deepHero)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Hero fills the remaining top space; content biased downward (2 units above,
                // 1 below) so the icon hovers just over the sheet.
                VStack(spacing: 0) {
                    Spacer(minLength: 8)
                    Spacer(minLength: 8)
                    hero()
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                sheet()
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, BolajonMetrics.screenPadding)
                    .padding(.top, 28)
                    .padding(.bottom, 10)
                    .background(
                        TopRoundedRectangle(radius: sheetRadius)
                            .fill(AppColors.cardWhite)
                            .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: -4)
                            .ignoresSafeArea(edges: .bottom)
                    )
            }
        }
        .navigationTitle(title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(blocksBack)
        // Keep the bar transparent so the hero tint runs continuously under it.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let progress {
                ToolbarItem(placement: .principal) {
                    PermissionProgressBar(current: progress.current, total: progress.total,
                                          mandatoryCount: mandatoryCount)
                }
            }
        }
    }
}

// MARK: - Card container

/// A white, softly-shadowed rounded container floated on a tinted ground.
struct InfoCard<Content: View>: View {
    var padding: CGFloat = BolajonMetrics.cardPadding
    var radius: CGFloat = BolajonMetrics.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(AppColors.cardWhite)
            )
            .shadow(
                color: BolajonMetrics.cardShadow,
                radius: BolajonMetrics.cardShadowRadius,
                x: 0,
                y: BolajonMetrics.cardShadowY
            )
    }
}

// MARK: - Icon badge

/// White circle containing a single tinted SF Symbol — used on every connect + permission screen.
struct IconBadge: View {
    let systemName: String
    var intent: ScreenIntent = .lavender
    var diameter: CGFloat = 92

    var body: some View {
        ZStack {
            Circle()
                .fill(AppColors.cardWhite)
                .shadow(color: BolajonMetrics.cardShadow, radius: diameter * 0.18, x: 0, y: diameter * 0.09)
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.36, weight: .semibold))
                .foregroundStyle(intent.glyphTint)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The Bolajon360 brand mark: a deep-indigo shield outline holding two figures (indigo + orange
/// heads over indigo shoulders). Drawn as vectors so it renders crisply at any size and needs no
/// asset. Used inside `BolajonBrandBadge`.
struct BolajonBrandLogo: View {
    var size: CGFloat = 60

    // Fixed brand colours (decorative mark — identical in light + dark, like the app icon).
    private let indigo = Color(.sRGB, red: 58 / 255, green: 44 / 255, blue: 134 / 255, opacity: 1)  // #3A2C86
    private let orange = Color(.sRGB, red: 240 / 255, green: 138 / 255, blue: 60 / 255, opacity: 1)  // #F08A3C

    var body: some View {
        ZStack {
            // Orange right shoulder — visible as a crescent between the navy wave and the
            // orange head (the board's mark shows it on the right side only).
            OrangeShoulder()
                .fill(orange)
                .clipShape(ShieldOutline())
            // Navy wave mass over it (leaves the orange crescent showing on the right).
            ShieldShoulders()
                .fill(indigo)
                .clipShape(ShieldOutline())
            // Heads.
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Circle().fill(indigo)
                    .frame(width: w * 0.31, height: w * 0.31)
                    .position(x: w * 0.365, y: h * 0.33)
                Circle().fill(orange)
                    .frame(width: w * 0.25, height: w * 0.25)
                    .position(x: w * 0.66, y: h * 0.37)
            }
            .clipShape(ShieldOutline())
            // Shield outline stroke on top.
            ShieldOutline()
                .stroke(indigo, style: StrokeStyle(lineWidth: size * 0.065, lineJoin: .round))
        }
        .frame(width: size, height: size * 1.06)
        .accessibilityHidden(true)
    }
}

/// Heraldic shield silhouette matching the board mark: near-straight top with small rounded
/// corners, straight upper sides, tapering to a rounded bottom point.
struct ShieldOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
        var p = Path()
        p.move(to: pt(0.06, 0.155))
        // Small rounded top-left corner, then a flat top edge.
        p.addQuadCurve(to: pt(0.135, 0.075), control: pt(0.06, 0.075))
        p.addLine(to: pt(0.865, 0.075))
        p.addQuadCurve(to: pt(0.94, 0.155), control: pt(0.94, 0.075))
        // Straight right side down to the taper.
        p.addLine(to: pt(0.94, 0.48))
        // Sweep to the rounded bottom point.
        p.addCurve(to: pt(0.55, 0.945), control1: pt(0.94, 0.70), control2: pt(0.72, 0.875))
        p.addQuadCurve(to: pt(0.45, 0.945), control: pt(0.50, 0.97))
        p.addCurve(to: pt(0.06, 0.48), control1: pt(0.28, 0.875), control2: pt(0.06, 0.70))
        p.closeSubpath()
        return p
    }
}

/// The merged "two figures" navy wave that fills the lower part of the shield. Its top edge
/// rides high over the left figure's shoulder, dips between the heads, and runs LOWER on the
/// right so the orange shoulder crescent stays visible beneath the orange head.
private struct ShieldShoulders: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
        var p = Path()
        p.move(to: pt(0.06, 0.56))
        p.addQuadCurve(to: pt(0.365, 0.455), control: pt(0.10, 0.455)) // rise over left shoulder
        p.addQuadCurve(to: pt(0.56, 0.585), control: pt(0.48, 0.48))   // dip between heads
        p.addQuadCurve(to: pt(0.94, 0.63), control: pt(0.76, 0.66))    // low run under the right side
        // Fill everything below, following the shield's own taper (overdrawn + clipped).
        p.addLine(to: pt(0.94, 1.0))
        p.addLine(to: pt(0.06, 1.0))
        p.closeSubpath()
        return p
    }
}

/// The orange right-shoulder hump, drawn beneath the navy wave.
private struct OrangeShoulder: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
        var p = Path()
        p.move(to: pt(0.50, 0.64))
        p.addQuadCurve(to: pt(0.66, 0.475), control: pt(0.52, 0.475)) // rise over the orange head's shoulders
        p.addQuadCurve(to: pt(0.94, 0.60), control: pt(0.84, 0.475))  // down to the right side
        p.addLine(to: pt(0.94, 0.85))
        p.addLine(to: pt(0.50, 0.85))
        p.closeSubpath()
        return p
    }
}

/// The Bolajon360 brand mark inside a soft white circle badge (hero use).
struct BolajonBrandBadge: View {
    var diameter: CGFloat = 130

    var body: some View {
        ZStack {
            Circle()
                .fill(AppColors.cardWhite)
                .shadow(color: BolajonMetrics.cardShadow, radius: 22, x: 0, y: 12)
            BolajonBrandLogo(size: diameter * 0.52)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The app's "connection" mark — a rounded diamond outline with a centred dot. Used where the
/// design shows the family-link glyph (A2 welcome feature, Settings "Ulanish holati").
struct ConnectionGlyph: View {
    var size: CGFloat = 20
    var tint: Color = AppColors.glyphPurple

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(tint, lineWidth: size * 0.11)
                .frame(width: size * 0.68, height: size * 0.68)
                .rotationEffect(.degrees(45))
            Circle().fill(tint)
                .frame(width: size * 0.16, height: size * 0.16)
                .offset(y: size * 0.05)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A broken-chain glyph (link + slash) for the disconnect affordances.
struct BrokenLinkIcon: View {
    var size: CGFloat = 18
    var tint: Color = AppColors.sosCoral

    var body: some View {
        ZStack {
            Image(systemName: "link")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
            Capsule()
                .fill(tint)
                .frame(width: size * 1.3, height: size * 0.16)
                .rotationEffect(.degrees(-45))
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .accessibilityHidden(true)
    }
}

/// A small drawn flag (no emoji — those tofu on the Simulator and aren't guaranteed).
struct MiniFlag: View {
    enum Kind { case uz, ru }
    let kind: Kind
    var width: CGFloat = 28
    var height: CGFloat = 20

    var body: some View {
        stripes
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(AppColors.hairline, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder private var stripes: some View {
        switch kind {
        case .uz:
            VStack(spacing: 0) {
                Color(red: 60 / 255, green: 175 / 255, blue: 225 / 255)   // sky blue
                Color(red: 214 / 255, green: 51 / 255, blue: 55 / 255).frame(height: 1) // red fimbriation
                Color.white
                Color(red: 214 / 255, green: 51 / 255, blue: 55 / 255).frame(height: 1)
                Color(red: 30 / 255, green: 170 / 255, blue: 106 / 255)   // green
            }
        case .ru:
            VStack(spacing: 0) {
                Color.white
                Color(red: 40 / 255, green: 70 / 255, blue: 160 / 255)
                Color(red: 200 / 255, green: 40 / 255, blue: 50 / 255)
            }
        }
    }
}

// MARK: - Buttons

/// Primary call-to-action: full-width purple pill.
struct BolajonPrimaryButton: View {
    let title: String
    var fill: Color = AppColors.ctaPurple
    var isLoading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Text(title)
                        .font(AppTypography.buttonLabel(16))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: BolajonMetrics.buttonHeight)
            .background(
                Capsule().fill(isEnabled ? fill : AppColors.chipNeutral)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled || isLoading)
        .animation(.easeInOut(duration: 0.15), value: isLoading)
    }

    private var isEnabled: Bool { !disabled && !isLoading }
}

/// Secondary / decline action: plain tinted text button ("Bekor qilish").
struct GhostButton: View {
    let title: String
    var tint: Color = AppColors.inkSecondary
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            Text(title)
                .font(AppTypography.bodyStrong(15))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Outline / decline pill: white fill, hairline border, dark label. Used for the "Yo'q, …"
/// decline option above the purple primary on the optional permission steps.
struct OutlineButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            Text(title)
                .font(AppTypography.buttonLabel(15))
                .foregroundStyle(AppColors.inkSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: BolajonMetrics.buttonHeight)
                .background(Capsule().fill(AppColors.cardWhite))
                .overlay(Capsule().stroke(AppColors.hairline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Permission progress bar

/// Progress indicator matching the design: completed steps are small filled dots, the current
/// step is an elongated pill, upcoming steps are faint grey dots. The mandatory segment
/// (`mandatoryCount` leading steps) is purple, the optional segment is orange. Sized for the
/// navigation bar's principal slot (intrinsic width).
struct PermissionProgressBar: View {
    /// 1-based index of the current step among the `total` permission steps.
    let current: Int
    let total: Int
    /// Leading steps drawn in purple; the rest in orange.
    var mandatoryCount: Int = 2

    private let purple = Color(.sRGB, red: 124 / 255, green: 92 / 255, blue: 252 / 255, opacity: 1)
    private let orange = Color(.sRGB, red: 240 / 255, green: 133 / 255, blue: 66 / 255, opacity: 1)

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< max(total, 1), id: \.self) { index in
                marker(at: index)
            }
        }
        .frame(height: 8)
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(current)/\(total)"))
    }

    @ViewBuilder
    private func marker(at index: Int) -> some View {
        let step = index + 1
        let color = index < mandatoryCount ? purple : orange
        if step == current {
            Capsule().fill(color).frame(width: 22, height: 7)
        } else if step < current {
            Circle().fill(color).frame(width: 7, height: 7)
        } else {
            Circle().fill(AppColors.hairline).frame(width: 7, height: 7)
        }
    }
}

// MARK: - Status pill

/// Yoqildi / O'chiq style status badge for the permission summary + settings.
struct StatusPill: View {
    enum State { case granted, off, neutral }

    let text: String
    var state: State = .neutral
    /// Optional leading SF Symbol (C5 shows "✓ Yoqilgan" / "! O'chiq").
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
            }
            Text(text).font(AppTypography.caption(12))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch state {
        case .granted: return AppColors.successGreen
        case .off: return AppColors.sosCoral
        case .neutral: return AppColors.inkSecondary
        }
    }

    private var background: Color {
        switch state {
        case .granted: return AppColors.successGreen.opacity(0.14)
        case .off: return AppColors.sosCoral.opacity(0.14)
        case .neutral: return AppColors.chipNeutral
        }
    }
}

// MARK: - Connected avatar

/// Emoji-in-circle avatar with a green "connected" indicator + check.
/// `filled` = solid green circle (A4 success); otherwise white circle with a green ring.
struct ConnectedAvatar: View {
    var emoji: String = "🦁"
    var diameter: CGFloat = 96
    var isConnected: Bool = true
    var ringColor: Color = AppColors.successGreen
    /// Solid green (connected) fill vs. a soft tinted circle.
    var filled: Bool = false
    /// Optional child profile color (from `child.profileColor`); softly tints the avatar
    /// circle when not `filled`. Nil falls back to the plain white card surface.
    var tint: Color?
    /// White ring around the circle (A4 success + Home header).
    var showRing: Bool = false
    /// Green check badge at the bottom-trailing (A4 success only).
    var showCheck: Bool = false
    /// Shown instead of the emoji when the runtime can't render emoji (e.g. the child's initial).
    var fallbackText: String? = nil

    private var fillColor: Color {
        if filled { return ringColor }
        return tint?.opacity(0.20) ?? AppColors.cardWhite
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(fillColor)
                avatarGlyph
            }
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle().stroke(ringStroke, lineWidth: showRing ? diameter * 0.045 : (filled ? 0 : 3))
            )
            .shadow(color: filled ? ringColor.opacity(0.28) : BolajonMetrics.cardShadow,
                    radius: diameter * 0.16, x: 0, y: diameter * 0.08)

            if showCheck {
                ZStack {
                    Circle().fill(ringColor)
                    Image(systemName: "checkmark")
                        .font(.system(size: diameter * 0.16, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: diameter * 0.30, height: diameter * 0.30)
                .overlay(Circle().stroke(AppColors.cardWhite, lineWidth: 3))
            }
        }
    }

    private var ringStroke: Color {
        if showRing { return .white }
        if filled { return .clear }
        return isConnected ? ringColor : AppColors.hairline
    }

    @ViewBuilder
    private var avatarGlyph: some View {
        if EmojiRenderCheck.systemRendersEmoji {
            Text(emoji).font(.system(size: diameter * 0.5))
        } else if let ch = fallbackText?.trimmingCharacters(in: .whitespaces).first {
            Text(String(ch).uppercased())
                .font(AppTypography.title(diameter * 0.42))
                .foregroundStyle(filled ? .white : AppColors.inkPrimary)
        } else {
            Image(systemName: "face.smiling.fill")
                .font(.system(size: diameter * 0.42))
                .foregroundStyle(filled ? .white : AppColors.inkSecondary)
        }
    }
}

// MARK: - Code entry (pairing / PIN)

/// Per-digit boxes + a custom numeric keypad. Reused by A3 Connect (5-digit pairing code)
/// and C6 Disconnect PIN (4 digits). Every call site passes an explicit `length`.
struct CodeEntryField: View {
    @Binding var code: String
    var length: Int = 5
    var intent: ScreenIntent = .lavender
    var showKeypad: Bool = true
    /// When true, fires `onComplete` automatically once `length` digits are entered.
    /// A3 Connect keeps this true and auto-submits once the fixed-length pairing code is full.
    var autoSubmit: Bool = true
    /// Render filled dots instead of per-digit boxes (used for the C6 disconnect PIN).
    var dotStyle: Bool = false
    /// Fill for the keypad keys. A3 sits on a white sheet → light-grey keys; C6 sits on the
    /// grey app ground → white keys.
    var keyFill: Color = AppColors.chipNeutral
    var onComplete: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 26) {
            if dotStyle { dots } else { boxes }
            if showKeypad {
                NumericKeypad(
                    keyFill: keyFill,
                    onDigit: appendDigit,
                    onBackspace: removeLast
                )
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0 ..< length, id: \.self) { index in
                Circle()
                    .fill(index < code.count ? AppColors.ctaPurple : Color.clear)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle().stroke(
                            index < code.count ? Color.clear : AppColors.inkTertiary.opacity(0.4),
                            lineWidth: 2
                        )
                    )
            }
        }
        .frame(height: 40)
    }

    private var boxes: some View {
        HStack(spacing: 10) {
            ForEach(0 ..< length, id: \.self) { index in
                let filled = index < code.count
                let isCursor = index == code.count
                let active = filled || isCursor
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.cardWhite)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(active ? AppColors.ctaPurple : AppColors.hairline,
                                    lineWidth: active ? 2 : 1)
                    )
                    .overlay(cursorContent(filled: filled, isCursor: isCursor, index: index))
                    .frame(height: 58)
            }
        }
    }

    @ViewBuilder
    private func cursorContent(filled: Bool, isCursor: Bool, index: Int) -> some View {
        if filled {
            Text(String(digit(at: index)))
                .font(AppTypography.heading(22))
                .foregroundStyle(AppColors.inkPrimary)
        } else if isCursor {
            // Blinking-style caret in the active box (design shows a thin purple bar).
            Capsule().fill(AppColors.ctaPurple).frame(width: 2, height: 22)
        }
    }

    private func digit(at index: Int) -> Character {
        let chars = Array(code)
        return index < chars.count ? chars[index] : " "
    }

    private func appendDigit(_ value: String) {
        guard code.count < length else { return }
        code += value
        AppHaptics.tap()
        if autoSubmit, code.count == length { onComplete?(code) }
    }

    private func removeLast() {
        guard !code.isEmpty else { return }
        code.removeLast()
        AppHaptics.tap()
    }
}

/// Reusable on-screen numeric keypad (1-9, 0, backspace).
struct NumericKeypad: View {
    var keyFill: Color = AppColors.chipNeutral
    let onDigit: (String) -> Void
    let onBackspace: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(1 ... 9, id: \.self) { number in
                key(String(number)) { onDigit(String(number)) }
            }
            Color.clear.frame(height: 56)
            key("0") { onDigit("0") }
            Button(action: onBackspace) {
                Image(systemName: "delete.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(AppColors.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.heading(24))
                .foregroundStyle(AppColors.inkPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(keyFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Screen scaffold

/// Full-bleed tinted screen with a scrollable content column. Used at the Home stack ROOT,
/// which keeps its navigation bar hidden in favor of the in-content header (design chrome);
/// pushed destinations use `BolajonScreen` and get the native bar.
struct ScreenScaffold<Content: View>: View {
    var intent: ScreenIntent = .lavender
    /// Overrides `intent.ground` — the "C" list screens use the lighter `screenBackground`.
    var background: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            (background ?? intent.ground).ignoresSafeArea()

            ScrollView {
                content
                    .padding(.horizontal, BolajonMetrics.screenPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
            }
            .appHiddenScrollIndicators()
        }
    }
}

private extension View {
    /// Hides scroll indicators on iOS 16+, no-op on iOS 15 (app deployment target).
    @ViewBuilder
    func appHiddenScrollIndicators() -> some View {
        if #available(iOS 16.0, *) {
            scrollIndicators(.hidden)
        } else {
            self
        }
    }
}

// MARK: - Screen scaffold v2 (native chrome)

/// Scaffold for destination screens inside a NavigationStack: tinted ground + scrolling
/// content column with NATIVE navigation chrome — the system navigation bar, the system
/// back button (and its edge-swipe pop), an inline `.navigationTitle`, and optional
/// permission-progress capsules in the bar's principal slot.
///
/// The lavender/peach grounds are uniform, so the default transparent scroll-edge
/// appearance is correct — no `.toolbarBackground` override needed.
struct BolajonScreen<Content: View>: View {
    var intent: ScreenIntent = .lavender
    /// Overrides `intent.ground` — the "C" list screens use the lighter `screenBackground`.
    var background: Color? = nil
    var title: String? = nil
    /// Blocks the system back button. Only for screens where popping would be wrong
    /// (A4 Success: the path was replaced, so back would return past a used pairing code).
    var blocksBack: Bool = false
    var progress: (current: Int, total: Int)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            (background ?? intent.ground).ignoresSafeArea()
            ScrollView {
                content
                    .padding(.horizontal, BolajonMetrics.screenPadding)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
            }
            .appHiddenScrollIndicators()
        }
        .navigationTitle(title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(blocksBack)
        .toolbar {
            if let progress {
                ToolbarItem(placement: .principal) {
                    PermissionProgressBar(current: progress.current, total: progress.total)
                }
            }
        }
    }
}

extension View {
    /// Hides the system navigation bar. Used ONLY at the Home stack root (C1), whose design
    /// chrome is the in-content header (avatar + name + gear); every pushed destination
    /// shows the native bar again, which also restores the native edge-swipe back.
    func appHiddenNavBar() -> some View {
        toolbar(.hidden, for: .navigationBar)
    }

    /// Brand tint for native navigation chrome (back chevron). Applied at each
    /// NavigationStack — the bar's controls take their tint from the stack, not from the
    /// destination's content. Content is unaffected in practice: Bolajon screens set
    /// their colors explicitly.
    func bolajonNavigationTint() -> some View {
        tint(AppColors.ctaPurple)
    }
}

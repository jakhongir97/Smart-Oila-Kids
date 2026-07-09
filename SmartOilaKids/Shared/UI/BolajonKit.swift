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
        case .peach: return AppColors.glyphCoral
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
                .shadow(color: BolajonMetrics.cardShadow, radius: 16, x: 0, y: 8)
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(intent.glyphTint)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The Bolajon360 brand mark (shield + family) inside a white circle badge.
/// Used on the setup + permissions-intro screens.
struct BolajonBrandBadge: View {
    var diameter: CGFloat = 92

    var body: some View {
        ZStack {
            Circle()
                .fill(AppColors.cardWhite)
                .shadow(color: BolajonMetrics.cardShadow, radius: 16, x: 0, y: 8)
            Image(systemName: "shield.fill")
                .font(.system(size: diameter * 0.46))
                .foregroundStyle(AppColors.glyphPurple)
            Image(systemName: "person.2.fill")
                .font(.system(size: diameter * 0.19, weight: .bold))
                .foregroundStyle(AppColors.cardWhite)
                .offset(y: diameter * 0.015)
        }
        .frame(width: diameter, height: diameter)
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

/// Secondary / decline action: plain tinted text button ("Yo'q, kerak emas").
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

// MARK: - Permission progress bar

/// Segmented progress capsules (purple→coral) for `current` of `total`. Back navigation is
/// the system back button; this view is sized for the navigation bar's principal slot
/// (see `BolajonScreen.progress`).
struct PermissionProgressBar: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< max(total, 1), id: \.self) { index in
                Capsule()
                    .fill(index < current ? fillColor(for: index) : AppColors.hairline)
                    .frame(height: 5)
            }
        }
        // Fixed width: principal toolbar items get no proposed width, and the capsules have
        // no intrinsic width of their own.
        .frame(width: 200, height: 5)
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(current)/\(total)"))
    }

    private func fillColor(for index: Int) -> Color {
        // Fixed (non-dynamic) brand endpoints so the gradient math doesn't depend on a
        // trait-resolved UIColor (which would freeze light-mode RGB). Decorative brand
        // gradient — intentionally the same in light and dark.
        let start = Color(.sRGB, red: 124 / 255, green: 92 / 255, blue: 252 / 255, opacity: 1) // ctaPurple
        let end = Color(.sRGB, red: 240 / 255, green: 96 / 255, blue: 90 / 255, opacity: 1)    // glyphCoral
        guard total > 1 else { return start }
        let t = Double(index) / Double(total - 1)
        return blend(start, end, t)
    }

    private func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ua = UIColor(a), ub = UIColor(b)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        ua.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        ub.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let f = CGFloat(t)
        return Color(
            red: Double(ar + (br - ar) * f),
            green: Double(ag + (bg - ag) * f),
            blue: Double(ab + (bb - ab) * f)
        )
    }
}

// MARK: - Status pill

/// Yoqildi / O'chiq style status badge for the permission summary + settings.
struct StatusPill: View {
    enum State { case granted, off, neutral }

    let text: String
    var state: State = .neutral

    var body: some View {
        Text(text)
            .font(AppTypography.caption(12))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
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
    var filled: Bool = false
    /// Optional child profile color (from `child.profileColor`); softly tints the avatar
    /// circle when not `filled`. Nil falls back to the plain white card surface.
    var tint: Color?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(filled ? ringColor : (tint?.opacity(0.20) ?? AppColors.cardWhite))
                Text(emoji).font(.system(size: diameter * 0.5))
            }
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle().stroke(
                    filled ? Color.clear : (isConnected ? ringColor : AppColors.hairline),
                    lineWidth: 4
                )
            )
            .shadow(color: filled ? ringColor.opacity(0.35) : BolajonMetrics.cardShadow, radius: 16, x: 0, y: 8)

            if isConnected {
                ZStack {
                    Circle().fill(ringColor)
                    Image(systemName: "checkmark")
                        .font(.system(size: diameter * 0.16, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: diameter * 0.32, height: diameter * 0.32)
                .overlay(Circle().stroke(AppColors.cardWhite, lineWidth: 3))
            }
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
    var onComplete: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 26) {
            if dotStyle { dots } else { boxes }
            if showKeypad {
                NumericKeypad(
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
        HStack(spacing: 8) {
            ForEach(0 ..< length, id: \.self) { index in
                let filled = index < code.count
                let isCursor = index == code.count
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColors.cardWhite)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isCursor ? intent.glyphTint : AppColors.hairline,
                                    lineWidth: isCursor ? 2 : 1)
                    )
                    .overlay(
                        Text(filled ? String(digit(at: index)) : "")
                            .font(AppTypography.heading(20))
                            .foregroundStyle(AppColors.inkPrimary)
                    )
                    .frame(height: 54)
            }
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
                        .fill(AppColors.cardWhite)
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
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            intent.ground.ignoresSafeArea()

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
    var title: String? = nil
    /// Blocks the system back button. Only for screens where popping would be wrong
    /// (A4 Success: the path was replaced, so back would return past a used pairing code).
    var blocksBack: Bool = false
    var progress: (current: Int, total: Int)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            intent.ground.ignoresSafeArea()
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

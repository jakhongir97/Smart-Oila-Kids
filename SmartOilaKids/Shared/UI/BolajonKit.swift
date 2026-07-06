import SwiftUI

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

/// Segmented top progress: filled pills (purple→coral) for `current` of `total`, with a back chevron.
struct PermissionProgressBar: View {
    let current: Int
    let total: Int
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                ChildTopBackButton(foreground: AppColors.inkPrimary, action: onBack)
            } else {
                Color.clear.frame(width: 30, height: 30)
            }

            HStack(spacing: 5) {
                ForEach(0 ..< max(total, 1), id: \.self) { index in
                    Capsule()
                        .fill(index < current ? fillColor(for: index) : AppColors.hairline)
                        .frame(height: 5)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: current)
        }
        .padding(.horizontal, BolajonMetrics.screenPadding)
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

/// Emoji-in-circle avatar with an optional green "connected" ring + check.
struct ConnectedAvatar: View {
    var emoji: String = "🦁"
    var diameter: CGFloat = 96
    var isConnected: Bool = true
    var ringColor: Color = AppColors.successGreen

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(AppColors.cardWhite)
                Text(emoji).font(.system(size: diameter * 0.5))
            }
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle().stroke(isConnected ? ringColor : AppColors.hairline, lineWidth: 4)
            )
            .shadow(color: BolajonMetrics.cardShadow, radius: 14, x: 0, y: 8)

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

/// Per-digit boxes + a custom numeric keypad. Reused by A3 Connect (8 digits)
/// and C6 Disconnect PIN (4 digits). Backend pairing codes are >= 8 chars.
struct CodeEntryField: View {
    @Binding var code: String
    var length: Int = 8
    var intent: ScreenIntent = .lavender
    var showKeypad: Bool = true
    /// When true, fires `onComplete` automatically once `length` digits are entered.
    /// A3 Connect sets this false and submits via an explicit button, since the backend
    /// pairing code is a *minimum* of 8 chars — auto-firing at exactly 8 could truncate.
    var autoSubmit: Bool = true
    var onComplete: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 26) {
            boxes
            if showKeypad {
                NumericKeypad(
                    onDigit: appendDigit,
                    onBackspace: removeLast
                )
            }
        }
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

/// Full-bleed tinted screen with an optional permission progress header and
/// a scrollable content column. Replaces per-view ZStack + ignoresSafeArea.
struct ScreenScaffold<Content: View>: View {
    var intent: ScreenIntent = .lavender
    var progress: (current: Int, total: Int)?
    var onBack: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            intent.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                if let progress {
                    PermissionProgressBar(current: progress.current, total: progress.total, onBack: onBack)
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                } else if let onBack {
                    HStack {
                        ChildTopBackButton(foreground: AppColors.inkPrimary, action: onBack)
                        Spacer()
                    }
                    .padding(.horizontal, BolajonMetrics.screenPadding)
                    .padding(.top, 8)
                }

                ScrollView {
                    content
                        .padding(.horizontal, BolajonMetrics.screenPadding)
                        .padding(.top, progress == nil && onBack == nil ? 8 : 0)
                        .padding(.bottom, 28)
                }
                .appHiddenScrollIndicators()
            }
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

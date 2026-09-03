import SwiftUI

/// Persistent, non-dismissable banner shown at the app root whenever the child's microphone is
/// live. This is the child-facing disclosure that keeps live audio NON-COVERT — required to stay
/// within App Store Guideline 5.1.2 (covert recording) for a monitoring app.
struct AudioListeningIndicator: View {
    /// audio ⇒ "parent is listening"; video ⇒ "parent is watching". Keeps the disclosure honest
    /// about which hardware is live.
    var mode: StreamMode = .audio
    /// True when the parent asked for video but the camera never opened (no grant, or the in-place
    /// swap failed) and only audio is live. Shown so the disclosure explains the mismatch instead of
    /// silently reading as a plain audio session.
    var videoUnavailable: Bool = false
    /// Ends the session. The child must be able to stop this themselves — a one-time consent tap
    /// that can never be withdrawn is not consent.
    var onStop: (() -> Void)?

    /// The bar's layout numbers, in one place because several are load-bearing rather than
    /// decorative: `stopHitTarget` is the only way a child can end a live session, and
    /// `topBreathing + bottomInset` is the space that keeps a BOTTOM-anchored bar from covering the
    /// content above it or the home indicator below it. All are pinned by
    /// `AudioListeningIndicatorLayoutTests`, so a future tidy-up of the paddings cannot quietly
    /// shrink the one control that must not be fiddly, nor let the bar overlap what it sits on.
    ///
    /// This bar lives at the BOTTOM of the screen (see `RootView.disclosing`). It rises up from
    /// below the home indicator when a session starts and drops back down when the microphone
    /// closes — the direction is the point: a disclosure that arrives from the bottom reads as "a
    /// tray slid up", the same vocabulary as a call bar or a now-playing strip, and its leaving is
    /// the child's confirmation the mic actually stopped.
    enum Metrics {
        /// Apple's minimum comfortable touch target, and the floor for the Stop control.
        static let stopHitTarget: CGFloat = 44
        /// Inside the capsule. Does NOT set the capsule's height — `stopHitTarget` does — so this is
        /// pure breathing room.
        static let capsulePaddingV: CGFloat = 5
        static let capsulePaddingH: CGFloat = 16
        /// Side margin, so the bar is a floating card with air either side rather than a full-bleed
        /// band. Also what caps the labels' width so a long translation clamps instead of running to
        /// the bezel.
        static let sideMargin: CGFloat = 14
        /// Gap ABOVE the bar, between it and the content it protects.
        static let topBreathing: CGFloat = 8
        /// Gap BELOW the drawn bar, lifting it clear of the home indicator so it settles just above
        /// the safe area rather than jammed against it.
        static let bottomInset: CGFloat = 6

        static var capsuleHeight: CGFloat { stopHitTarget + capsulePaddingV * 2 }
        /// Total height the disclosure claims in the root stack, above the safe area.
        static var rowHeight: CGFloat { topBreathing + capsuleHeight + bottomInset }
        /// Corner radius of the floating card. Half the capsule height keeps the ends fully round.
        static var cornerRadius: CGFloat { capsuleHeight / 2 }
    }

    private var label: String {
        mode == .video ? L10n.tr("audio2.watching") : L10n.tr("audio2.listening")
    }

    var body: some View {
        HStack(spacing: 8) {
            // A static recording dot, not a pulsing one. The pulse was a `repeatForever` animation
            // living on the app's ROOT view for the whole session — a permanent redraw on a child's
            // battery, and a never-ending transaction that fights the insertion transition RootView
            // now gives this row. The disclosure does its job by being present and legible, not by
            // moving; dropping it also retires the reduce-motion special case this view carried for
            // it.
            ZStack {
                Circle().stroke(Color.white.opacity(0.55), lineWidth: 2).frame(width: 14, height: 14)
                Circle().fill(Color.white).frame(width: 8, height: 8)
            }
            Image(systemName: mode == .video ? "video.fill" : "waveform")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white)
            // Both lines are clamped. The capsule hugs its content, so before the outer horizontal
            // padding below there was nothing to clamp AGAINST and a long translation simply grew
            // the capsule past the screen edge — "Камера не открылась — только звук" at 1.35x
            // Dynamic Type is the case that does it. One line each, shrink rather than wrap: this
            // row must stay one compact strip, and a two-line label would also push the Stop button
            // down the screen mid-session.
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(AppTypography.bodyStrong(13))
                    .foregroundStyle(Color.white)
                if videoUnavailable {
                    Text(L10n.tr("audio2.camera_unavailable"))
                        .font(AppTypography.caption(11))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            if let onStop {
                Button(action: onStop) {
                    Text(L10n.tr("audio2.stop"))
                        .font(AppTypography.bodyStrong(13))
                        // Coral on the white capsule measured 3.11:1, under the 4.5:1 that 13pt bold
                        // needs, so the Stop label takes the deep end of the gradient (#B20C0C):
                        // ~7.5:1 on white, and it visually ties the button to the bar it ends.
                        .foregroundStyle(AppColors.livePresenceCoralDeep)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("audio2.stop")))
                // 44pt. This is the child's ONLY way to end a session they can see running, on a bar
                // deliberately sized to stay unobtrusive — the one control in the app that must not
                // be fiddly. `contentShape` makes the whole frame tappable, not just the capsule.
                .frame(minWidth: Metrics.stopHitTarget, minHeight: Metrics.stopHitTarget)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, Metrics.capsulePaddingH)
        .padding(.vertical, Metrics.capsulePaddingV)
        // A floating rounded card with a coral→deep-red gradient, so the bar reads as a solid tray
        // rather than a flat sticker. The shadow throws UPWARD (negative y) because the bar sits at
        // the bottom and the light it implies comes from the content above it — a downward shadow on
        // a bottom bar looks like it is peeling off the screen.
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(AppColors.livePresenceGradient)
        )
        .overlay(
            // A hairline top highlight, the standard trick that makes a gradient surface look lit
            // rather than printed. Purely decorative; carries no contrast burden.
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: AppColors.livePresenceCoralDeep.opacity(0.45), radius: 14, x: 0, y: -3)
        // Side margins, applied AFTER the background so they cap the card's width — without this the
        // hugging HStack proposed its ideal width to the labels, they never had a reason to shrink,
        // and a long translation ran to the bezel.
        .padding(.horizontal, Metrics.sideMargin)
        // The bar is a BOTTOM row: breathing room above it, a small lift above the home indicator
        // below. `RootView.disclosing` places the whole disclosure below the app content, so this
        // padding reserves the gaps and the bar can never overlap either neighbour — the non-overlap
        // that is the entire reason the disclosure is a sibling row and not a floating overlay.
        .padding(.top, Metrics.topBreathing)
        .padding(.bottom, Metrics.bottomInset)
        .accessibilityElement(children: .contain)
        // `label`, not the audio string: VoiceOver must say "watching" when the camera is what is
        // live, exactly as the visible text does.
        .accessibilityLabel(Text(label))
    }
}

/// One-time consent shown to the child before the microphone — or, for a video session, the camera —
/// is ever opened. Honest and plain: what the parent can do, and that the child will always see the
/// indicator while it's on. The mic and the camera are asked for SEPARATELY: a tap that allowed an
/// audio check must never be what opens the camera, so `mode` drives the copy and the icon.
/// Carries the consent sheet's own content height up to the detent that presents it.
private struct ConsentSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct AudioConsentSheet: View {
    var mode: StreamMode = .audio
    let onAllow: () -> Void
    let onDecline: () -> Void

    /// Resting sheet height, measured from the content rather than assumed. See the detent below.
    ///
    /// The floor was 440pt, which on the 812pt phone this is tested on covered well over half the
    /// screen for a sheet whose content is a title, two short lines and two buttons — Ibrohim's item
    /// 5, *"sal kompaktroq qilib pastga tushirib qo'yish kerak"*. On a bottom sheet "move it down"
    /// and "make it smaller" are the same instruction: the sheet is already pinned to the bottom
    /// edge, so the only way it sits lower is by being shorter.
    ///
    /// It is a FLOOR, not a height. Everything that made 440 necessary still holds — Cyrillic Uzbek
    /// runs materially longer than Latin, the video wording is longer than the audio wording, and
    /// Dynamic Type scales all of it — and all of that is handled by measuring the content, which is
    /// unchanged. Lowering the floor only stops the sheet padding itself out to 440 when its content
    /// genuinely needs 330.
    @State private var restingHeight: CGFloat = Metrics.minimumResting

    /// The whole compactness policy, in one place and reachable from tests — the clamp below is
    /// meaningless without the two bounds side by side, and `AudioConsentSheetLayoutTests` pins the
    /// property that actually matters: the floor must stay clear of the cap, or a long translation
    /// would be clamped BELOW its own content and the buttons would leave the screen again.
    enum Metrics {
        /// Floor. Stops a short sheet padding itself out to a number measured once in English.
        static let minimumResting: CGFloat = 340
        /// Cap. Keeps a long sheet a sheet rather than a full-screen takeover; `.large` and the
        /// scroll are what make the overflow reachable.
        static let maximumResting: CGFloat = 620

        static func resting(forMeasured measured: CGFloat) -> CGFloat {
            min(max(measured, minimumResting), maximumResting)
        }
    }

    private var title: String {
        mode == .video ? L10n.tr("audio2.consent.video.title") : L10n.tr("audio2.consent.title")
    }

    private var message: String {
        mode == .video ? L10n.tr("audio2.consent.video.body") : L10n.tr("audio2.consent.body")
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(AppColors.ctaPurple.opacity(0.14)).frame(width: 64, height: 64)
                Image(systemName: mode == .video ? "video.fill" : "waveform.and.mic")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(AppColors.ctaPurple)
            }
            .padding(.top, 2)

            VStack(spacing: 8) {
                Text(title)
                    .font(AppTypography.title(19))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(AppTypography.bodyText(14))
                    .foregroundStyle(AppColors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Image(systemName: "eye.fill").foregroundStyle(AppColors.sosCoral)
                Text(L10n.tr("audio2.consent.hint"))
                    .font(AppTypography.caption(12))
                    .foregroundStyle(AppColors.inkTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(AppColors.chipNeutral))

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Button(action: onAllow) {
                    Text(L10n.tr("audio2.consent.allow"))
                        .font(AppTypography.bodyStrong(16))
                        .foregroundStyle(AppColors.inverseTextPrimary)
                        .frame(maxWidth: .infinity)
                        // 14pt keeps the 44pt minimum hit target intact at default type; the saving
                        // comes from the stack spacing and the hero above, never from the controls.
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppColors.ctaPurple))
                }
                .buttonStyle(.plain)
                Button(action: onDecline) {
                    Text(L10n.tr("audio2.consent.decline"))
                        .font(AppTypography.bodyStrong(15))
                        .foregroundStyle(AppColors.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 18)
        // Same treatment the SOS sheet already got, and for the same reason — this sheet was simply
        // missed. Its height is not fixed: the title, the body and the hint are all translated into
        // three languages (Cyrillic Uzbek runs materially longer than Latin), the video wording is
        // longer than the audio wording, and the child's Dynamic Type setting scales every line of
        // it. Against a fixed 440pt detent with no scroll, the `Spacer(minLength: 0)` above the
        // buttons collapses first and then Allow / Not now slide off the bottom edge.
        //
        // This is the one sheet where that is unrecoverable rather than annoying. It is the gate in
        // front of the microphone: a child who cannot reach "Allow" cannot consent, so no live
        // session can ever start and the parent simply sees a device that never answers. A paired
        // iPhone in this exact state — uz-Cyrl, consent never granted — is what sent us looking.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ConsentSheetHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ConsentSheetHeightKey.self) { measured in
            // The sheet is as tall as its content instead of a number someone measured once in
            // English at default text. The floor stops a short sheet padding itself out; the cap
            // keeps a long one a sheet rather than a full-screen takeover.
            restingHeight = Metrics.resting(forMeasured: measured)
        }
        .scrollableIfNeeded()
        // Measured resting height, plus `.large` to drag to. The scroll guarantees every control is
        // REACHABLE even at the largest accessibility sizes; the measured detent is what stops a
        // child having to discover that by scrolling a sheet that looks finished. The drag indicator
        // was already visible and, until now, lied — there was nowhere to drag to.
        .presentationDetents([.height(restingHeight), .large])
        .presentationDragIndicator(.visible)
    }
}

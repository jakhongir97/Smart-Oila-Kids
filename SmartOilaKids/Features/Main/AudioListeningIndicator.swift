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

    /// The banner's layout numbers, in one place because two of them are load-bearing rather than
    /// decorative: `stopHitTarget` is the only way a child can end a live session, and
    /// `loweredBy == bottomInset` is what keeps a lowered banner from covering the screen beneath it.
    /// Both are pinned by `AudioListeningIndicatorLayoutTests`, so a future tidy-up of the paddings
    /// cannot quietly shrink the one control that must not be fiddly.
    enum Metrics {
        /// Apple's minimum comfortable touch target, and the floor for this row's height.
        static let stopHitTarget: CGFloat = 44
        /// Inside the capsule. Does NOT set the capsule's height — `stopHitTarget` does — so this is
        /// pure breathing room and the first thing to give when the ask is "make it more compact".
        static let capsulePaddingV: CGFloat = 4
        static let capsulePaddingH: CGFloat = 14
        /// Outside the capsule: the margin that caps its width so the labels have something to clamp
        /// against, and the row's own top inset.
        static let rowInsetH: CGFloat = 12
        static let topInset: CGFloat = 2
        /// How far the drawn capsule is pushed down inside its row, and — necessarily equal — the
        /// bottom padding that reserves that distance so nothing below is overlapped.
        static let loweredBy: CGFloat = 8

        static var capsuleHeight: CGFloat { stopHitTarget + capsulePaddingV * 2 }
        /// Total height the disclosure claims in the root stack.
        static var rowHeight: CGFloat { topInset + capsuleHeight + loweredBy }
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
                        // The same problem inverted: coral on the white capsule measured 3.11:1,
                        // under the 4.5:1 that 13pt bold needs. Matches the banner's fill too.
                        .foregroundStyle(AppColors.livePresenceCoral)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("audio2.stop")))
                // 44pt, and the comment that used to sit here claimed it already was. It was 32:
                // 13pt of text plus 5pt of padding each side is ~26pt of drawn capsule, and the
                // `minHeight` was the only thing extending it. This is the child's ONLY way to end a
                // session they can see running, on a banner deliberately sized to be unobtrusive —
                // the one control in the app that must not be fiddly. `contentShape` makes the whole
                // frame tappable rather than just the capsule inside it.
                .frame(minWidth: Metrics.stopHitTarget, minHeight: Metrics.stopHitTarget)
                .contentShape(Rectangle())
            }
        }
        // Compact, per the product owner's item 5. The 44pt Stop frame — not this padding — is what
        // sets the capsule's height, so trimming the vertical padding from 9 to 4 is a real 10pt
        // saving and takes nothing off the hit target: the capsule is now exactly the 44pt target
        // plus 8pt of breathing room, which is as short as this row can honestly get while the only
        // way to end a session stays a full-size control.
        .padding(.horizontal, Metrics.capsulePaddingH)
        .padding(.vertical, Metrics.capsulePaddingV)
        .background(Capsule().fill(AppColors.livePresenceCoral))
        .shadow(color: AppColors.livePresenceCoral.opacity(0.4), radius: 10, x: 0, y: 4)
        // Outer margin, applied AFTER the background so it does not pad the capsule's inside. This
        // is what caps the capsule's width — without it the hugging HStack proposed its ideal width
        // to the labels, they never had a reason to shrink, and a long translation ran to the bezel.
        .padding(.horizontal, Metrics.rowInsetH)
        // Lowered, also per item 5. The offset moves the DRAWN capsule down while `bottom` reserves
        // the same distance in the row, so the disclosure still cannot overlap the screen underneath
        // it — that non-overlap is the entire reason RootView gives this a row of its own instead of
        // an overlay, and it survives this change. Net against build 13: the capsule's top edge sits
        // 4pt lower (6 → 10) while the row it occupies is 6pt shorter (68 → 62).
        .padding(.top, Metrics.topInset)
        .padding(.bottom, Metrics.loweredBy)
        .offset(y: Metrics.loweredBy)
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
    @State private var restingHeight: CGFloat = 440

    private var title: String {
        mode == .video ? L10n.tr("audio2.consent.video.title") : L10n.tr("audio2.consent.title")
    }

    private var message: String {
        mode == .video ? L10n.tr("audio2.consent.video.body") : L10n.tr("audio2.consent.body")
    }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(AppColors.ctaPurple.opacity(0.14)).frame(width: 84, height: 84)
                Image(systemName: mode == .video ? "video.fill" : "waveform.and.mic")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(AppColors.ctaPurple)
            }
            .padding(.top, 12)

            VStack(spacing: 10) {
                Text(title)
                    .font(AppTypography.title(20))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(AppTypography.bodyText(15))
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

            VStack(spacing: 10) {
                Button(action: onAllow) {
                    Text(L10n.tr("audio2.consent.allow"))
                        .font(AppTypography.bodyStrong(16))
                        .foregroundStyle(AppColors.inverseTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
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
        .padding(24)
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
            // English at default text. 440pt stays the floor so the design is unchanged where it
            // already fitted; the cap keeps it a sheet rather than a full-screen takeover.
            restingHeight = min(max(measured, 440), 700)
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

import SwiftUI

struct GeoPermissionChecklistStageView: View {
    @ObservedObject var manager: LocationPermissionManager
    @Binding var selectedRequirement: PermissionRequirement?
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

                Text(L10n.tr("permissions.requirements_title"))
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppColors.black)
                    .lineSpacing(2)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, compact ? 24 : 51)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: compact ? 12 : 15) {
                        mediaReadinessCard

                        ForEach(PermissionRequirement.allCases) { requirement in
                            permissionRow(requirement: requirement)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, compact ? 16 : 26)
                    .padding(.bottom, 12)
                }

                ChildPrimaryButton(
                    title: L10n.tr("common.next"),
                    background: AppColors.accentGreen,
                    trailingArrow: true,
                    disabled: !manager.allChecklistSatisfied
                ) {
                    guard manager.allChecklistSatisfied else { return }
                    onContinue()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
            .onAppear {
                manager.refreshStatuses()
            }
        }
    }

    private var mediaReadinessCard: some View {
        let isReady = manager.mediaReadinessSatisfied
        let accentColor = isReady ? AppColors.accentGreen : AppColors.dangerRed

        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("permissions.media_readiness_title"))
                .font(AppTypography.unbounded(12, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            Text(manager.mediaReadinessMessage())
                .font(AppTypography.unbounded(10, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                .lineSpacing(2)

            VStack(spacing: 8) {
                ForEach(manager.mediaCapabilityStatuses) { capability in
                    mediaCapabilityRow(capability)
                }
            }
            .padding(.top, 2)

            Text(
                isReady
                    ? L10n.tr("permissions.media_readiness_status_ready")
                    : L10n.tr("permissions.media_readiness_status_incomplete")
            )
            .font(AppTypography.unbounded(10, weight: .semibold))
            .foregroundStyle(accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(accentColor.opacity(0.12))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColor.opacity(0.35), lineWidth: 2)
        }
    }

    private func mediaCapabilityRow(_ capability: MediaCapabilityStatus) -> some View {
        let accentColor: Color
        switch capability.state {
        case .ready:
            accentColor = AppColors.accentGreen
        case .inactive:
            accentColor = AppColors.primaryPurple
        case .actionNeeded, .unavailable:
            accentColor = AppColors.dangerRed
        }

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(capability.title)
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)

                Text(capability.detail)
                    .font(AppTypography.unbounded(9, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 8)

            Text(capability.badgeText)
                .font(AppTypography.unbounded(8, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(accentColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func permissionRow(requirement: PermissionRequirement) -> some View {
        let isOn = manager.isSatisfied(requirement)
        let isInteractive = manager.isInteractive(requirement)
        let borderColor = isOn ? AppColors.accentGreen : AppColors.neutral200
        let toggleBinding = permissionBinding(for: requirement)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr(requirement.titleKey))
                    .font(AppTypography.unbounded(14, weight: .medium))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                Text(manager.statusText(for: requirement))
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(isOn ? AppColors.accentGreen : AppColors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Button {
                selectedRequirement = requirement
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.primaryPurple)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("main.info_title"))

            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .disabled(!isInteractive)
                .opacity(isInteractive ? 1.0 : 0.65)
                .tint(AppColors.accentGreen)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 4)
        }
    }

    private func permissionBinding(for requirement: PermissionRequirement) -> Binding<Bool> {
        Binding(
            get: { manager.isSatisfied(requirement) },
            set: { newValue in
                guard manager.isInteractive(requirement) else { return }

                guard newValue else {
                    manager.refreshStatuses()
                    return
                }

                AppHaptics.tap()
                manager.performAction(for: requirement)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    manager.refreshStatuses()
                }
            }
        )
    }
}

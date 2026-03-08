import SwiftUI

struct SettingsPermissionsPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: LocationPermissionManager

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("settings.permissions_subtitle"))
                        .font(AppTypography.unbounded(12, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.top, 4)

                    SettingsMediaReadinessCard(manager: manager)

                    ForEach(PermissionRequirement.allCases) { requirement in
                        SettingsPermissionRow(requirement: requirement, manager: manager)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AppColors.white.ignoresSafeArea())
            .navigationTitle(L10n.tr("settings.permissions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("common.close")) {
                        dismiss()
                    }
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        manager.refreshStatuses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppColors.primaryPurple)
                    }
                }
            }
            .onAppear {
                manager.refreshStatuses()
            }
        }
    }
}

struct SettingsMediaReadinessCard: View {
    @ObservedObject var manager: LocationPermissionManager

    var body: some View {
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
                    capabilityRow(capability)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColor.opacity(0.35), lineWidth: 2)
        }
    }

    private func capabilityRow(_ capability: MediaCapabilityStatus) -> some View {
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
        .background(AppColors.white.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SettingsPermissionRow: View {
    let requirement: PermissionRequirement
    @ObservedObject var manager: LocationPermissionManager

    var body: some View {
        let isSatisfied = manager.isSatisfied(requirement)
        let borderColor = isSatisfied ? AppColors.accentGreen : AppColors.neutral200
        let actionTitle = manager.primaryActionTitle(for: requirement)
        let canAct = manager.isInteractive(requirement) && !isSatisfied && actionTitle != nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L10n.tr(requirement.titleKey))
                    .font(AppTypography.unbounded(13, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Toggle("", isOn: permissionBinding)
                    .labelsHidden()
                    .disabled(!manager.isInteractive(requirement))
                    .tint(AppColors.accentGreen)
            }

            Text(manager.statusText(for: requirement))
                .font(AppTypography.unbounded(11, weight: .regular))
                .foregroundStyle(isSatisfied ? AppColors.accentGreen : AppColors.textSecondary)
                .lineLimit(3)

            HStack {
                if canAct, let actionTitle {
                    Button(actionTitle) {
                        AppHaptics.tap()
                        manager.performAction(for: requirement)
                    }
                    .font(AppTypography.unbounded(11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(AppColors.primaryPurple)
                    .clipShape(Capsule())
                } else if isSatisfied {
                    Text(L10n.tr("permissions.status_granted"))
                        .font(AppTypography.unbounded(11, weight: .semibold))
                        .foregroundStyle(AppColors.accentGreen)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(AppColors.accentGreen.opacity(0.12))
                        .clipShape(Capsule())
                } else {
                    Text(manager.statusText(for: requirement))
                        .font(AppTypography.unbounded(11, weight: .semibold))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(AppColors.neutral200.opacity(0.55))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 2)
        }
    }

    private var permissionBinding: Binding<Bool> {
        Binding(
            get: { manager.isSatisfied(requirement) },
            set: { newValue in
                guard manager.isInteractive(requirement) else { return }

                // iOS permission toggles cannot be force-disabled in-app once granted.
                // Ignore "off" attempts and refresh visual state.
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

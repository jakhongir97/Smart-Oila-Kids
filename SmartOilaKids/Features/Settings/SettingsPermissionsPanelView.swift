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

private struct SettingsPermissionRow: View {
    let requirement: PermissionRequirement
    @ObservedObject var manager: LocationPermissionManager

    var body: some View {
        let isSatisfied = manager.isSatisfied(requirement)
        let borderColor = isSatisfied ? AppColors.accentGreen : AppColors.neutral200
        let actionTitle = manager.primaryActionTitle(for: requirement) ?? L10n.tr("permissions.action_open_settings")
        let canAct = manager.isInteractive(requirement) && !isSatisfied

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
                if canAct {
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
                } else {
                    Text(L10n.tr("permissions.status_granted"))
                        .font(AppTypography.unbounded(11, weight: .semibold))
                        .foregroundStyle(AppColors.accentGreen)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(AppColors.accentGreen.opacity(0.12))
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

import SwiftUI

struct PermissionDetailsSheet: View {
    let requirement: PermissionRequirement
    @ObservedObject var manager: LocationPermissionManager

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.tr("permissions.details_title"))
                        .font(AppTypography.unbounded(18, weight: .semibold))
                        .foregroundStyle(AppColors.black)

                    Text(L10n.tr(requirement.titleKey))
                        .font(AppTypography.unbounded(16, weight: .semibold))
                        .foregroundStyle(AppColors.primaryPurple)

                    detailsCard(
                        title: L10n.tr("permissions.details_why_title"),
                        body: L10n.tr(requirement.detailBodyKey)
                    )

                    detailsCard(
                        title: L10n.tr("permissions.details_how_title"),
                        body: L10n.tr(requirement.detailStepKey)
                    )

                    detailsCard(
                        title: L10n.tr("permissions.details_status_title"),
                        body: manager.statusText(for: requirement),
                        bodyColor: manager.isSatisfied(requirement)
                            ? AppColors.accentGreen
                            : AppColors.textSecondary
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if let actionTitle = manager.primaryActionTitle(for: requirement) {
                        ChildPrimaryButton(
                            title: actionTitle,
                            background: AppColors.accentGreen,
                            trailingArrow: false
                        ) {
                            manager.performAction(for: requirement)
                        }
                    }

                    ChildPrimaryButton(
                        title: L10n.tr("common.done"),
                        background: AppColors.neutral100,
                        textColor: AppColors.black,
                        trailingArrow: false
                    ) {
                        dismiss()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(AppColors.white)
            }
            .background(AppColors.white)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("common.close")) {
                        dismiss()
                    }
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }
            }
            .onAppear {
                manager.refreshStatuses()
            }
        }
    }

    private func detailsCard(
        title: String,
        body: String,
        bodyColor: Color = AppColors.black
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppTypography.unbounded(12, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)

            Text(body)
                .font(AppTypography.unbounded(12, weight: .regular))
                .foregroundStyle(bodyColor)
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

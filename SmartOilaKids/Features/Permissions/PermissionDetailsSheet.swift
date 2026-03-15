import SwiftUI

struct PermissionDetailsSheet: View {
    let requirement: PermissionRequirement
    @ObservedObject var manager: LocationPermissionManager

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppNavigationContainer {
            GeometryReader { proxy in
                let bottomInset = max(12, proxy.safeAreaInsets.bottom + 4)

                ZStack {
                    AppColors.white
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        HStack {
                            Color.clear
                                .frame(width: 30, height: 30)

                            Spacer()

                            Text(L10n.tr("permissions.details_title"))
                                .font(AppTypography.unbounded(18, weight: .semibold))
                                .foregroundStyle(AppColors.black)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)

                            Spacer()

                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AppColors.primaryPurple)
                                    .frame(width: 30, height: 30)
                                    .background(AppColors.surfacePurple.opacity(0.16))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.tr("common.close"))
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 18)

                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 16) {
                                requirementHero

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
                            .padding(.bottom, 10)
                        }

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
                        .padding(.bottom, bottomInset)
                    }
                }
                .onAppear {
                    manager.refreshStatuses()
                }
            }
            .modifier(PermissionDetailsNavigationHider())
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
                .foregroundStyle(AppColors.primaryPurple)

            Text(body)
                .font(AppTypography.unbounded(12, weight: .regular))
                .foregroundStyle(bodyColor)
                .lineSpacing(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColors.surfacePurple.opacity(0.45), lineWidth: 1)
        }
    }

    private var requirementHero: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(iconBackgroundColor)
                    .frame(width: 52, height: 52)

                Image(systemName: requirementIcon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(iconForegroundColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr(requirement.titleKey))
                    .font(AppTypography.unbounded(16, weight: .semibold))
                    .foregroundStyle(AppColors.black)

                Text(manager.statusText(for: requirement))
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(manager.isSatisfied(requirement) ? AppColors.accentGreen : AppColors.textSecondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surfacePurple.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var requirementIcon: String {
        if manager.isSatisfied(requirement) {
            return "checkmark"
        }

        switch requirement {
        case .location:
            return "location.fill"
        case .usageStats:
            return "hourglass"
        case .notifications:
            return "bell.fill"
        case .microphone:
            return "mic.fill"
        case .camera:
            return "camera.fill"
        }
    }

    private var iconBackgroundColor: Color {
        manager.isSatisfied(requirement)
            ? AppColors.accentGreen.opacity(0.18)
            : AppColors.surfacePurple.opacity(0.22)
    }

    private var iconForegroundColor: Color {
        manager.isSatisfied(requirement) ? AppColors.accentGreen : AppColors.primaryPurple
    }
}

private struct PermissionDetailsNavigationHider: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbar(.hidden, for: .navigationBar)
        } else {
            content.navigationBarHidden(true)
        }
    }
}

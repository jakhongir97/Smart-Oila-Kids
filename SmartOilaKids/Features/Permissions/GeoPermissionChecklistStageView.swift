import SwiftUI

struct GeoPermissionChecklistStageView: View {
    private let referenceSize = CGSize(width: 412, height: 917)

    @ObservedObject var manager: LocationPermissionManager
    @Binding var selectedRequirement: PermissionRequirement?
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / referenceSize.width, proxy.size.height / referenceSize.height)
            let compact = scale < 0.9
            let scaled = { (value: CGFloat) in value * scale }
            let horizontalPadding = scaled(30)
            let surfacePadding = scaled(16)
            let buttonHorizontalPadding = scaled(31)
            let bottomInset = max(scaled(35), proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

                HStack {
                    Spacer()
                    AuthLanguageBadge()
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, scaled(11))

                Text(L10n.tr("permissions.requirements_title"))
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppColors.black)
                    .lineSpacing(2)
                    .frame(maxWidth: scaled(320))
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, scaled(24))

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        VStack(spacing: compact ? scaled(12) : scaled(14)) {
                            ForEach(PermissionRequirement.onboardingCases) { requirement in
                                permissionRow(requirement: requirement)
                            }
                        }
                        .padding(.horizontal, surfacePadding)
                        .padding(.vertical, scaled(18))
                        .background(
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .fill(AppColors.surfacePurple.opacity(0.14))
                        )
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, scaled(28))
                    .padding(.bottom, scaled(12))
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
                .padding(.horizontal, buttonHorizontalPadding)
                .padding(.bottom, bottomInset)
            }
            .onAppear {
                manager.refreshStatuses()
            }
        }
    }

    private func permissionRow(requirement: PermissionRequirement) -> some View {
        let isOn = manager.isSatisfied(requirement)
        let isInteractive = manager.isInteractive(requirement)
        let borderColor = isOn ? AppColors.accentGreen : AppColors.neutral200
        let toggleBinding = permissionBinding(for: requirement)

        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(isOn ? AppColors.accentGreen.opacity(0.18) : AppColors.neutral100)
                    .frame(width: 42, height: 42)

                Image(systemName: requirementIcon(requirement, isSatisfied: isOn))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOn ? AppColors.accentGreen : AppColors.primaryPurple)
            }

            VStack(alignment: .leading, spacing: 5) {
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

            VStack(spacing: 12) {
                Button {
                    selectedRequirement = requirement
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.primaryPurple)
                        .frame(width: 32, height: 32)
                        .background(AppColors.surfacePurple.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("main.info_title"))

                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .disabled(!isInteractive)
                    .opacity(isInteractive ? 1.0 : 0.65)
                    .tint(AppColors.accentGreen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(borderColor, lineWidth: isOn ? 2 : 1)
        }
    }

    private func permissionBinding(for requirement: PermissionRequirement) -> Binding<Bool> {
        Binding(
            get: { manager.isSatisfied(requirement) },
            set: { newValue in
                AppHaptics.tap()
                manager.handleToggleChange(for: requirement, isEnabled: newValue)
            }
        )
    }

    private func requirementIcon(_ requirement: PermissionRequirement, isSatisfied: Bool) -> String {
        if isSatisfied {
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
}

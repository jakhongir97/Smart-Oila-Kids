import SwiftUI

struct GeoPermissionView: View {
    private enum Stage {
        case intro
        case checklist
        case done
    }

    @ObservedObject var manager: LocationPermissionManager
    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .intro
    @State private var selectedRequirement: PermissionRequirement?

    init(manager: LocationPermissionManager) {
        self.manager = manager
#if DEBUG
        if let stage = Self.debugInitialStage {
            _stage = State(initialValue: stage)
        }
#endif
    }

    var body: some View {
        ZStack {
            AppColors.white.ignoresSafeArea()

            switch stage {
            case .intro:
                introLikeStage(
                    title: L10n.tr("permissions.setup_title"),
                    subtitle: L10n.tr("permissions.setup_subtitle"),
                    buttonTitle: L10n.tr("common.next"),
                    trailingArrow: true
                ) {
                    stage = .checklist
                }
            case .checklist:
                checklistStage
            case .done:
                introLikeStage(
                    title: L10n.tr("permissions.done_title"),
                    subtitle: L10n.tr("permissions.done_subtitle"),
                    buttonTitle: L10n.tr("common.home"),
                    trailingArrow: false
                ) {
                    dismiss()
                }
            }
        }
        .onAppear {
            manager.refreshStatuses()
        }
        .sheet(item: $selectedRequirement) { requirement in
            PermissionDetailsSheet(requirement: requirement, manager: manager)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func introLikeStage(
        title: String,
        subtitle: String,
        buttonTitle: String,
        trailingArrow: Bool,
        action: @escaping () -> Void
    ) -> some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

                Spacer(minLength: compact ? 26 : 52)

                SmartOilaWordmark()
                    .scaleEffect(compact ? 0.88 : 1.0)

                Text(title)
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .padding(.top, compact ? 18 : 30)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPadding)

                Text(subtitle)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, compact ? 8 : 10)

                Spacer(minLength: compact ? 14 : 24)

                ChildPrimaryButton(
                    title: buttonTitle,
                    background: AppColors.accentGreen,
                    trailingArrow: trailingArrow,
                    action: action
                )
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
        }
    }

    private var checklistStage: some View {
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
                    stage = .done
                }
                .padding(.horizontal, 20)
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

private struct PermissionDetailsSheet: View {
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
                        bodyColor: manager.isSatisfied(requirement) ? AppColors.accentGreen : AppColors.textSecondary
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

private extension GeoPermissionView {
    private static var debugInitialStage: Stage? {
        switch AppRuntime.debugPermissionsStage {
        case .intro:
            return .intro
        case .checklist:
            return .checklist
        case .done:
            return .done
        case nil:
            return nil
        }
    }
}

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
    @State private var toggles = Array(repeating: false, count: 7)

    private let permissionTitles = [
        L10n.tr("permissions.item_1"),
        L10n.tr("permissions.item_2"),
        L10n.tr("permissions.item_3"),
        L10n.tr("permissions.item_4"),
        L10n.tr("permissions.item_5"),
        L10n.tr("permissions.item_6"),
        L10n.tr("permissions.item_7")
    ]

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
                    manager.requestLocationPermission()
                    dismiss()
                }
            }
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
                ChildStatusBar()

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
                ChildStatusBar()

                Text(L10n.tr("permissions.requirements_title"))
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppColors.black)
                    .lineSpacing(2)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, compact ? 24 : 51)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: compact ? 12 : 15) {
                        ForEach(permissionTitles.indices, id: \.self) { index in
                            permissionRow(index: index)
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
                    disabled: !toggles.allSatisfy { $0 }
                ) {
                    guard toggles.allSatisfy({ $0 }) else { return }
                    stage = .done
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
        }
    }

    private func permissionRow(index: Int) -> some View {
        let isOn = toggles[index]

        return HStack(spacing: 12) {
            Text(permissionTitles[index])
                .font(AppTypography.unbounded(14, weight: .medium))
                .foregroundStyle(AppColors.black)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Spacer()

            Button {
                toggles[index].toggle()
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .stroke(isOn ? AppColors.accentGreen : AppColors.neutral200, lineWidth: 4)
                        .frame(width: 50, height: 25)

                    Circle()
                        .fill(isOn ? AppColors.accentGreen : AppColors.neutral200)
                        .frame(width: 21, height: 21)
                        .padding(.horizontal, 2)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isOn ? AppColors.accentGreen : AppColors.neutral200, lineWidth: 4)
        }
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

import SwiftUI

struct GeoPermissionView: View {
    enum Stage {
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
                GeoPermissionIntroStageView(
                    title: L10n.tr("permissions.setup_title"),
                    subtitle: L10n.tr("permissions.setup_subtitle"),
                    buttonTitle: L10n.tr("common.next"),
                    trailingArrow: true,
                    action: {
                    stage = .checklist
                    }
                )
            case .checklist:
                GeoPermissionChecklistStageView(
                    manager: manager,
                    selectedRequirement: $selectedRequirement,
                    onContinue: {
                        stage = .done
                    }
                )
            case .done:
                GeoPermissionIntroStageView(
                    title: L10n.tr("permissions.done_title"),
                    subtitle: L10n.tr("permissions.done_subtitle"),
                    buttonTitle: L10n.tr("common.home"),
                    trailingArrow: false,
                    action: dismiss.callAsFunction
                )
            }
        }
        .onAppear {
            manager.refreshStatuses()
        }
        .sheet(item: $selectedRequirement) { requirement in
            PermissionDetailsSheet(requirement: requirement, manager: manager)
                .appMediumLargeSheetPresentation()
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

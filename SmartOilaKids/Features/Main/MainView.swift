import SwiftUI

struct MainView: View {
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel: MainViewModel
    @StateObject private var locationPermissionManager = LocationPermissionManager()

    @State private var showChat = false
    @State private var showTasks = false
    @State private var showSettings = false
    @State private var showTemplates = false

    init(viewModel: MainViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding = adaptiveHorizontalPadding(for: proxy.size.width)
            let sectionSpacing = proxy.size.height < 760 ? 16.0 : 20.0
            let compact = proxy.size.height < 760

            ZStack(alignment: .bottomTrailing) {
                AppColors.surfacePurple
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    AppColors.white
                        .frame(height: proxy.safeAreaInsets.top)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    MainHeaderSection(
                        profileName: sessionStore.profileName,
                        onInfoTap: { showTemplates = true },
                        onNotificationTap: { viewModel.alertText = L10n.tr("main.no_notifications") },
                        onSettingsTap: { showSettings = true }
                    )

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: sectionSpacing) {
                            MainAdInfoCard()

                            WeeklyUsageChartCard(compact: compact)

                            MainPrimaryActions(
                                onTasksTap: { showTasks = true },
                                onChatTap: { showChat = true }
                            )
                            .padding(.top, sectionSpacing)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 15)
                        .padding(.bottom, max(36, proxy.safeAreaInsets.bottom + 18))
                    }
                }

                ChildWatermarkOverlay(opacity: 0.45)
            }
        }
        .fullScreenCover(isPresented: $showChat) {
            NavigationStack {
                ChatView(viewModel: dependencies.makeChatViewModel(dsn: sessionStore.dsn ?? ""))
            }
        }
        .fullScreenCover(isPresented: $showTasks) {
            NavigationStack {
                TaskView(viewModel: dependencies.makeTaskViewModel(dsn: sessionStore.dsn ?? ""))
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(viewModel: dependencies.makeSettingsViewModel())
            }
            .environmentObject(sessionStore)
        }
        .fullScreenCover(isPresented: $showTemplates) {
            NavigationStack {
                TemplatesView()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !isDebugRouteMode && locationPermissionManager.locationIsNotGranted },
            set: { _ in }
        )) {
            GeoPermissionView(manager: locationPermissionManager)
        }
        .alert(L10n.tr("main.info_title"), isPresented: Binding(get: {
            viewModel.alertText != nil
        }, set: { newValue in
            if !newValue {
                viewModel.alertText = nil
            }
        }), actions: {
            Button(L10n.tr("common.ok")) { viewModel.alertText = nil }
        }, message: {
            Text(viewModel.alertText ?? "")
        })
    }

    private func adaptiveHorizontalPadding(for width: CGFloat) -> CGFloat {
        min(30, max(16, width * 0.06))
    }

    private var isDebugRouteMode: Bool {
        AppRuntime.hasDebugRoute
    }
}

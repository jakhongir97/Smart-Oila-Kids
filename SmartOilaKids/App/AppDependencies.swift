import SwiftUI

struct AppDependencies {
    static let live = AppDependencies(apiClient: APIClient())

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    @MainActor
    func makeAuthViewModel() -> AuthViewModel {
        AuthViewModel(authService: AuthService(client: apiClient))
    }

    @MainActor
    func makeMainViewModel() -> MainViewModel {
        let tasksService = TaskService(client: apiClient)
        let chatService = ChatService(client: apiClient)
        return MainViewModel(
            sosService: SOSService(client: apiClient),
            dashboardService: MainDashboardService(client: apiClient),
            taskSummaryService: tasksService,
            chatService: chatService
        )
    }

    @MainActor
    func makeChatViewModel(dsn: String) -> ChatViewModel {
        ChatViewModel(
            dsn: dsn,
            service: ChatService(client: apiClient),
            webSocketService: ChatWebSocketService()
        )
    }

    @MainActor
    func makeTaskViewModel(dsn: String) -> TaskViewModel {
        TaskViewModel(dsn: dsn, service: TaskService(client: apiClient))
    }

    @MainActor
    func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(service: SettingsService(client: apiClient))
    }

    private let apiClient: APIClient
}

private struct AppDependenciesEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppDependencies.live
}

extension EnvironmentValues {
    var appDependencies: AppDependencies {
        get { self[AppDependenciesEnvironmentKey.self] }
        set { self[AppDependenciesEnvironmentKey.self] = newValue }
    }
}

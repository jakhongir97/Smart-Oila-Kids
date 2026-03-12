import Foundation

struct MainViewModelDependencies {
    let sosService: SOSServicing
    let dashboardService: MainDashboardServicing
    let taskSummaryService: TaskSummaryServicing
    let chatService: ChatServicing
    let chatReadStateStore: ChatReadStateStoring
    let chatHistoryStore: ChatHistoryCaching
    let taskCacheStore: TaskCacheStoring
}

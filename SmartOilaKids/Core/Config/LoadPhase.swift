import Foundation

enum LoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

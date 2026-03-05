import SwiftUI

@MainActor
final class SettingsBannerCenter: ObservableObject {
    @Published private(set) var text: String?

    deinit {
        hideTask?.cancel()
    }

    func show(_ text: String, duration: TimeInterval = 1.8) {
        hideTask?.cancel()

        withAnimation {
            self.text = text
        }

        hideTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self?.text = nil
                }
            }
        }
    }

    private var hideTask: Task<Void, Never>?
}

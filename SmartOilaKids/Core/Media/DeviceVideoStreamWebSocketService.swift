import Foundation

actor DeviceVideoStreamWebSocketService {
    func connect(dsn: String) {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else { return }

        if let connectedDSN,
           connectedDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame,
           task != nil,
           reconnectTask == nil,
           !isDisconnectRequested {
            return
        }

        disconnect()

        isDisconnectRequested = false
        connectedDSN = normalizedDSN
        currentBaseIndex = 0
        reconnectAttemptCount = 0
        connectUsingCurrentBase()
    }

    func disconnect() {
        isDisconnectRequested = true
        connectedDSN = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func send(_ data: Data) async -> Bool {
        guard let task else {
            return false
        }

        do {
            try await task.send(.data(data))
            return true
        } catch {
            if self.task === task {
                self.task = nil
            }
            if !isDisconnectRequested {
                connectNextBase()
            }
            return false
        }
    }

    private func connectUsingCurrentBase() {
        guard let dsn = connectedDSN else { return }

        guard currentBaseIndex < AppConfig.websocketBaseCandidates.count else {
            scheduleReconnect()
            return
        }

        let base = AppConfig.websocketBaseCandidates[currentBaseIndex]
        let urlString = "\(base)\(AppConfig.websocketTokenPath)/children/device/\(dsn)/stream/camera"
        guard let url = URL(string: urlString) else {
            connectNextBase()
            return
        }

        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(baseIndex: currentBaseIndex, task: task)
    }

    private func connectNextBase() {
        guard !isDisconnectRequested else { return }

        currentBaseIndex += 1
        if currentBaseIndex < AppConfig.websocketBaseCandidates.count {
            connectUsingCurrentBase()
            return
        }

        currentBaseIndex = 0
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !isDisconnectRequested else { return }

        reconnectAttemptCount += 1
        reconnectTask?.cancel()

        let delay = reconnectDelay(forAttempt: reconnectAttemptCount)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.connectUsingCurrentBase()
        }
    }

    private func receiveLoop(baseIndex: Int, task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { [weak self] in
                await self?.handleReceiveResult(result, baseIndex: baseIndex, task: task)
            }
        }
    }

    private func handleReceiveResult(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        baseIndex: Int,
        task: URLSessionWebSocketTask
    ) {
        guard self.task === task else { return }

        switch result {
        case .success:
            reconnectAttemptCount = 0
            receiveLoop(baseIndex: baseIndex, task: task)
        case .failure:
            self.task = nil
            if !isDisconnectRequested, baseIndex == currentBaseIndex {
                connectNextBase()
            }
        }
    }

    private func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        let clamped = max(1, min(attempt, 6))
        let backoff = pow(2.0, Double(clamped - 1))
        return min(baseReconnectDelay * backoff, maxReconnectDelay)
    }

    private var connectedDSN: String?
    private var currentBaseIndex = 0
    private var isDisconnectRequested = false
    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptCount = 0
    private let baseReconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 20
}

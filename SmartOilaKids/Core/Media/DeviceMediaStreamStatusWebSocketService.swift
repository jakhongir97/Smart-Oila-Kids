import Foundation

final class DeviceMediaStreamStatusWebSocketService {
    var onStatusEvent: ((DeviceMediaStreamStatusEvent) -> Void)?

    func connect(dsn: String) {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else { return }

        if let connectedDSN,
           connectedDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame,
           task != nil,
           reconnectWorkItem == nil,
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
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connectUsingCurrentBase() {
        guard let dsn = connectedDSN else { return }

        guard currentBaseIndex < AppConfig.websocketBaseCandidates.count else {
            scheduleReconnect()
            return
        }

        let base = AppConfig.websocketBaseCandidates[currentBaseIndex]
        let urlString = "\(base)\(AppConfig.websocketTokenPath)/children/device/\(dsn)/stream/status"
        guard let url = URL(string: urlString) else {
            connectNextBase()
            return
        }

        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        receiveLoop(baseIndex: currentBaseIndex)
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
        reconnectWorkItem?.cancel()

        let delay = reconnectDelay(forAttempt: reconnectAttemptCount)
        let item = DispatchWorkItem { [weak self] in
            self?.connectUsingCurrentBase()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func receiveLoop(baseIndex: Int) {
        task?.receive { [weak self] result in
            switch result {
            case let .success(message):
                self?.reconnectAttemptCount = 0

                switch message {
                case let .data(data):
                    self?.handleIncoming(data: data)
                case let .string(string):
                    self?.handleIncoming(data: Data(string.utf8))
                @unknown default:
                    break
                }

                self?.receiveLoop(baseIndex: baseIndex)
            case .failure:
                guard let self else { return }
                self.task = nil
                if !self.isDisconnectRequested, baseIndex == self.currentBaseIndex {
                    self.connectNextBase()
                }
            }
        }
    }

    private func handleIncoming(data: Data) {
        guard let event = parser.parse(from: data) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onStatusEvent?(event)
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
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttemptCount = 0
    private let parser = DeviceMediaStreamStatusPayloadParser()
    private let baseReconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 20
}

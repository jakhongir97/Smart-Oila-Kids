import Foundation

actor DeviceVideoStreamWebSocketService {
    func connect(dsn: String, streamType: DeviceMediaStreamType = .camera) {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else { return }

        if let connectedDSN,
           let connectedStreamType,
           connectedDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame,
           connectedStreamType == streamType,
           task != nil,
           reconnectTask == nil,
           !isDisconnectRequested {
            return
        }

        disconnect()

        isDisconnectRequested = false
        connectedDSN = normalizedDSN
        connectedStreamType = streamType
        currentCandidateIndex = 0
        reconnectAttemptCount = 0
        connectUsingCurrentCandidate()
    }

    func disconnect() {
        isDisconnectRequested = true
        connectedDSN = nil
        connectedStreamType = nil
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
                connectNextCandidate()
            }
            return false
        }
    }

    private func connectUsingCurrentCandidate() {
        guard let dsn = connectedDSN, let streamType = connectedStreamType else { return }
        let candidates = endpointCandidates(for: dsn, streamType: streamType)

        guard currentCandidateIndex < candidates.count else {
            scheduleReconnect()
            return
        }

        let url = candidates[currentCandidateIndex]
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(candidateIndex: currentCandidateIndex, task: task)
    }

    private func connectNextCandidate() {
        guard !isDisconnectRequested else { return }

        currentCandidateIndex += 1
        if let connectedDSN,
           let connectedStreamType,
           currentCandidateIndex < endpointCandidates(for: connectedDSN, streamType: connectedStreamType).count {
            connectUsingCurrentCandidate()
            return
        }

        currentCandidateIndex = 0
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
            await self?.connectUsingCurrentCandidate()
        }
    }

    private func receiveLoop(candidateIndex: Int, task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { [weak self] in
                await self?.handleReceiveResult(result, candidateIndex: candidateIndex, task: task)
            }
        }
    }

    private func handleReceiveResult(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        candidateIndex: Int,
        task: URLSessionWebSocketTask
    ) {
        guard self.task === task else { return }

        switch result {
        case .success:
            reconnectAttemptCount = 0
            receiveLoop(candidateIndex: candidateIndex, task: task)
        case .failure:
            self.task = nil
            if !isDisconnectRequested, candidateIndex == currentCandidateIndex {
                connectNextCandidate()
            }
        }
    }

    private func endpointCandidates(
        for dsn: String,
        streamType: DeviceMediaStreamType
    ) -> [URL] {
        let legacyRoute: String
        let v2Route: String

        switch streamType {
        case .audio:
            legacyRoute = "/children/device/\(dsn)/stream/audio"
            v2Route = "/v2/children/device/\(dsn)/stream/audio"
        case .camera:
            legacyRoute = "/children/device/\(dsn)/stream/camera"
            v2Route = "/v2/children/device/\(dsn)/stream/camera"
        case .frontCamera:
            legacyRoute = "/children/device/\(dsn)/stream/front_camera"
            v2Route = "/v2/children/device/\(dsn)/stream/front_camera"
        }

        let routeSuffixes: [String]
        switch AppConfig.mediaStreamWebSocketMode {
        case .legacyOnly:
            routeSuffixes = [legacyRoute]
        case .v2Preferred:
            routeSuffixes = [v2Route, legacyRoute]
        case .v2Only:
            routeSuffixes = [v2Route]
        }

        return routeSuffixes.flatMap { suffix in
            AppConfig.websocketBaseCandidates.compactMap { base in
                URL(string: "\(base)\(AppConfig.websocketTokenPath)\(suffix)")
            }
        }
    }

    private func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        let clamped = max(1, min(attempt, 6))
        let backoff = pow(2.0, Double(clamped - 1))
        return min(baseReconnectDelay * backoff, maxReconnectDelay)
    }

    private var connectedDSN: String?
    private var connectedStreamType: DeviceMediaStreamType?
    private var currentCandidateIndex = 0
    private var isDisconnectRequested = false
    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptCount = 0
    private let baseReconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 20
}

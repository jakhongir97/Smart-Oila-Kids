import Foundation

@MainActor
final class DeviceLockCoordinator: ObservableObject {
    struct State: Equatable {
        var isLocked: Bool
        var deviceLocalTime: String?
        var scheduleRange: String?

        static let unlocked = State(isLocked: false, deviceLocalTime: nil, scheduleRange: nil)
    }

    @Published private(set) var state: State = .unlocked
    @Published private(set) var lastErrorText: String?

    init(service: DeviceLockServicing = DeviceLockService()) {
        self.service = service
    }

    func start(dsn: String?) {
        guard let normalized = dsn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            stop()
            return
        }

        guard normalized != currentDSN else { return }

        pollingTask?.cancel()
        pollingTask = nil
        currentDSN = normalized
        state = .unlocked
        lastErrorText = nil
        resetGlobalLockCache()

        pollingTask = Task { [weak self] in
            await self?.pollLoop(for: normalized)
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        currentDSN = nil
        state = .unlocked
        lastErrorText = nil
        resetGlobalLockCache()
    }

    func refreshNow() async {
        guard let dsn = currentDSN else { return }
        await refreshStatus(for: dsn)
    }

    private func pollLoop(for dsn: String) async {
        await refreshStatus(for: dsn)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
            guard !Task.isCancelled else { break }
            await refreshStatus(for: dsn)
        }
    }

    private func refreshStatus(for dsn: String) async {
        guard currentDSN == dsn else { return }

        do {
            let status = try await service.fetchFullLockStatus(dsn: dsn)
            let globalLockStatus = await resolveGlobalLockStatus(dsn: dsn) ?? false
            guard currentDSN == dsn else { return }

            state = State(
                isLocked: status.isLocked || globalLockStatus,
                deviceLocalTime: status.normalizedLocalTime,
                scheduleRange: status.schedule?.normalizedRange
            )
            lastErrorText = nil
        } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
            guard currentDSN == dsn else { return }
            if let globalLockStatus = await resolveGlobalLockStatus(dsn: dsn) {
                state = State(
                    isLocked: globalLockStatus,
                    deviceLocalTime: nil,
                    scheduleRange: nil
                )
                lastErrorText = nil
            } else {
                // Keep current lock state when global fallback is unavailable.
                lastErrorText = nil
            }
        } catch {
            guard currentDSN == dsn else { return }
            if let globalLockStatus = await resolveGlobalLockStatus(dsn: dsn) {
                state = State(
                    isLocked: globalLockStatus,
                    deviceLocalTime: state.deviceLocalTime,
                    scheduleRange: state.scheduleRange
                )
                lastErrorText = nil
            } else {
                // Keep current lock state on temporary network errors.
                lastErrorText = error.localizedDescription
            }
        }
    }

    private func resolveGlobalLockStatus(dsn: String) async -> Bool? {
        do {
            let value = try await service.fetchGlobalLockStatus(dsn: dsn)
            lastKnownGlobalLockStatus = value
            lastKnownGlobalLockUpdatedAt = Date()
            return value
        } catch {
            return cachedGlobalLockStatus()
        }
    }

    private func cachedGlobalLockStatus(referenceDate: Date = Date()) -> Bool? {
        guard let value = lastKnownGlobalLockStatus,
              let updatedAt = lastKnownGlobalLockUpdatedAt,
              referenceDate.timeIntervalSince(updatedAt) <= globalLockCacheTTL else {
            return nil
        }
        return value
    }

    private func resetGlobalLockCache() {
        lastKnownGlobalLockStatus = nil
        lastKnownGlobalLockUpdatedAt = nil
    }

    private let service: DeviceLockServicing
    private var currentDSN: String?
    private var pollingTask: Task<Void, Never>?
    private let pollingIntervalNanoseconds: UInt64 = 15_000_000_000
    private let globalLockCacheTTL: TimeInterval = 120
    private var lastKnownGlobalLockStatus: Bool?
    private var lastKnownGlobalLockUpdatedAt: Date?
}

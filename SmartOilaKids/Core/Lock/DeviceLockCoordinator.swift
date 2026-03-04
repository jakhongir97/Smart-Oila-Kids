import Foundation

protocol DeviceLockServicing {
    func fetchFullLockStatus(dsn: String) async throws -> DeviceFullLockStatus
    func fetchGlobalLockStatus(dsn: String) async throws -> Bool
}

final class DeviceLockService: DeviceLockServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func fetchFullLockStatus(dsn: String) async throws -> DeviceFullLockStatus {
        let normalized = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        return try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/dsn/\(normalized)/full_lock_status",
            method: .get,
            headers: ["Accept": "application/json"],
            as: DeviceFullLockStatus.self
        )
    }

    func fetchGlobalLockStatus(dsn: String) async throws -> Bool {
        let normalized = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        let data = try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/dsn/\(normalized)/global_application_lock",
            method: .get,
            headers: ["Accept": "application/json"]
        )

        if let value = try? JSONDecoder().decode(Bool.self, from: data) {
            return value
        }

        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let boolValue = payload["is_locked"] as? Bool {
                return boolValue
            }
            if let boolValue = payload["global_application_lock"] as? Bool {
                return boolValue
            }
            if let boolValue = payload["value"] as? Bool {
                return boolValue
            }
            if let number = payload["is_locked"] as? NSNumber {
                return number.boolValue
            }
            if let number = payload["global_application_lock"] as? NSNumber {
                return number.boolValue
            }
            if let number = payload["value"] as? NSNumber {
                return number.boolValue
            }
        }

        throw NetworkError.decodingFailed
    }

    private let client: APIClient
}

struct DeviceFullLockStatus: Decodable {
    let isLocked: Bool
    let deviceLocalTime: String?
    let schedule: DeviceFullLockSchedule?

    enum CodingKeys: String, CodingKey {
        case isLocked = "is_locked"
        case deviceLocalTime = "device_local_time"
        case schedule
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isLocked = container.decodeLossyBoolIfPresent(forKey: .isLocked) ?? false
        deviceLocalTime = container.decodeLossyStringIfPresent(forKey: .deviceLocalTime)
        schedule = try? container.decodeIfPresent(DeviceFullLockSchedule.self, forKey: .schedule)
    }

    var normalizedLocalTime: String? {
        DeviceFullLockStatus.normalizeTime(deviceLocalTime)
    }

    private static func normalizeTime(_ value: String?) -> String? {
        guard var normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }

        if let dotIndex = normalized.firstIndex(of: ".") {
            normalized = String(normalized[..<dotIndex])
        }

        if normalized.count >= 5,
           normalized.contains(":") {
            return String(normalized.prefix(5))
        }

        return normalized
    }
}

struct DeviceFullLockSchedule: Decodable {
    let startTime: String?
    let endTime: String?
    let isScheduleEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case isScheduleEnabled = "is_schedule_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startTime = container.decodeLossyStringIfPresent(forKey: .startTime)
        endTime = container.decodeLossyStringIfPresent(forKey: .endTime)
        isScheduleEnabled = container.decodeLossyBoolIfPresent(forKey: .isScheduleEnabled)
    }

    var normalizedRange: String? {
        guard isScheduleEnabled ?? true else { return nil }
        guard let start = normalizeTime(startTime),
              let end = normalizeTime(endTime) else {
            return nil
        }
        return "\(start) - \(end)"
    }

    private func normalizeTime(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.count >= 5,
           value.contains(":") {
            return String(value.prefix(5))
        }

        return value
    }
}

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
            let globalLockStatus = (try? await service.fetchGlobalLockStatus(dsn: dsn)) ?? false
            guard currentDSN == dsn else { return }

            state = State(
                isLocked: status.isLocked || globalLockStatus,
                deviceLocalTime: status.normalizedLocalTime,
                scheduleRange: status.schedule?.normalizedRange
            )
            lastErrorText = nil
        } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
            guard currentDSN == dsn else { return }
            if let globalLockStatus = try? await service.fetchGlobalLockStatus(dsn: dsn) {
                state = State(
                    isLocked: globalLockStatus,
                    deviceLocalTime: nil,
                    scheduleRange: nil
                )
                lastErrorText = nil
            } else {
                state = .unlocked
                lastErrorText = nil
            }
        } catch {
            guard currentDSN == dsn else { return }
            if let globalLockStatus = try? await service.fetchGlobalLockStatus(dsn: dsn) {
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

    private let service: DeviceLockServicing
    private var currentDSN: String?
    private var pollingTask: Task<Void, Never>?
    private let pollingIntervalNanoseconds: UInt64 = 15_000_000_000
}

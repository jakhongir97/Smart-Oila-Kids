import Foundation

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

import DeviceActivity
import Foundation
import ManagedSettings

@MainActor
final class DeviceLockScheduleMonitorController {
    func applySchedule(_ schedule: DeviceFullLockSchedule?, dsn: String?) {
        ScreenTimeAuthorizationManager.shared.refreshStatus()

        let normalizedDSN = normalizedDSN(dsn)
        let authorizationStatus = ScreenTimeAuthorizationManager.shared.status
        let configuration = makeConfiguration(schedule: schedule, dsn: normalizedDSN)
        let newSignature = configuration?.signature

        if newSignature == currentSignature {
            updateDiagnostics(
                status: configuration == nil ? (normalizedDSN == nil ? "idle" : "disabled") : "monitoring",
                dsn: normalizedDSN ?? "-",
                schedule: configuration?.summary ?? schedule?.normalizedRange ?? "-",
                activityCount: configuration?.activities.count ?? 0,
                lastError: "-"
            )
            return
        }

        stopCurrentMonitoring()

        guard let normalizedDSN else {
            updateDiagnostics(
                status: "idle",
                dsn: "-",
                schedule: "-",
                activityCount: 0,
                lastError: "-"
            )
            return
        }

        guard let configuration else {
            updateDiagnostics(
                status: "disabled",
                dsn: normalizedDSN,
                schedule: schedule?.normalizedRange ?? "-",
                activityCount: 0,
                lastError: "-"
            )
            return
        }

        guard authorizationStatus == .granted else {
            updateDiagnostics(
                status: authorizationStatus == .unavailable ? "unavailable" : "not_authorized",
                dsn: normalizedDSN,
                schedule: configuration.summary,
                activityCount: 0,
                lastError: "-"
            )
            return
        }

        do {
            for activity in configuration.activities {
                try activityCenter.startMonitoring(activity.name, during: activity.schedule)
            }

            currentSignature = configuration.signature
            currentActivities = configuration.activities.map(\.name)
            updateDiagnostics(
                status: "monitoring",
                dsn: normalizedDSN,
                schedule: configuration.summary,
                activityCount: configuration.activities.count,
                lastError: "-"
            )
        } catch {
            stopCurrentMonitoring()
            updateDiagnostics(
                status: "failed",
                dsn: normalizedDSN,
                schedule: configuration.summary,
                activityCount: 0,
                lastError: error.localizedDescription
            )
        }
    }

    func stop() {
        stopCurrentMonitoring()
        updateDiagnostics(
            status: "idle",
            dsn: "-",
            schedule: "-",
            activityCount: 0,
            lastError: "-"
        )
    }

    private let activityCenter = DeviceActivityCenter()
    private let scheduleStore = ManagedSettingsStore(named: .init(DeviceLockManagedSettingsStoreName.schedule))
    private var currentSignature: String?
    private var currentActivities: [DeviceActivityName] = []
}

private extension DeviceLockScheduleMonitorController {
    struct MonitoringActivity {
        let name: DeviceActivityName
        let schedule: DeviceActivitySchedule
    }

    struct MonitoringConfiguration {
        let summary: String
        let signature: String
        let activities: [MonitoringActivity]
    }

    func makeConfiguration(schedule: DeviceFullLockSchedule?, dsn: String?) -> MonitoringConfiguration? {
        guard let schedule,
              schedule.isScheduleEnabled ?? true,
              let dsn,
              let windows = monitoringWindows(from: schedule, dsn: dsn),
              !windows.isEmpty else {
            return nil
        }

        let summary = schedule.normalizedRange ?? windows.map(\.0).joined(separator: ", ")
        let signature = "\(dsn)|\(summary)|\(windows.map(\.0).joined(separator: ","))"
        let activities = windows.compactMap { _, activity in activity }
        return MonitoringConfiguration(summary: summary, signature: signature, activities: activities)
    }

    func monitoringWindows(
        from schedule: DeviceFullLockSchedule,
        dsn: String
    ) -> [(String, MonitoringActivity)]? {
        guard let startMinutes = parseMinutes(schedule.startTime),
              let endMinutes = parseMinutes(schedule.endTime),
              startMinutes != endMinutes else {
            return nil
        }

        if startMinutes < endMinutes {
            guard let activity = makeActivity(
                dsn: dsn,
                suffix: "primary",
                startMinutes: startMinutes,
                endMinutes: endMinutes
            ) else {
                return nil
            }
            return [("\(startMinutes)-\(endMinutes)", activity)]
        }

        var windows: [(String, MonitoringActivity)] = []

        if let lateWindow = makeActivity(
            dsn: dsn,
            suffix: "late",
            startMinutes: startMinutes,
            endMinutes: (23 * 60) + 59
        ) {
            windows.append(("\(startMinutes)-1439", lateWindow))
        }

        if let earlyWindow = makeActivity(
            dsn: dsn,
            suffix: "early",
            startMinutes: 0,
            endMinutes: endMinutes
        ) {
            windows.append(("0-\(endMinutes)", earlyWindow))
        }

        return windows.isEmpty ? nil : windows
    }

    func makeActivity(
        dsn: String,
        suffix: String,
        startMinutes: Int,
        endMinutes: Int
    ) -> MonitoringActivity? {
        guard startMinutes < endMinutes else { return nil }

        let schedule = DeviceActivitySchedule(
            intervalStart: timeComponents(from: startMinutes),
            intervalEnd: timeComponents(from: endMinutes),
            repeats: true
        )

        return MonitoringActivity(
            name: DeviceActivityName(DeviceLockScheduleActivityIdentifier.rawValue(dsn: dsn, suffix: suffix)),
            schedule: schedule
        )
    }

    func parseMinutes(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        let components = value.split(separator: ":")
        guard components.count >= 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0 ..< 24).contains(hour),
              (0 ..< 60).contains(minute) else {
            return nil
        }

        return (hour * 60) + minute
    }

    func timeComponents(from minutes: Int) -> DateComponents {
        DateComponents(hour: minutes / 60, minute: minutes % 60)
    }

    func stopCurrentMonitoring() {
        if !currentActivities.isEmpty {
            activityCenter.stopMonitoring(currentActivities)
        }
        currentActivities = []
        currentSignature = nil
        scheduleStore.clearAllSettings()
    }

    func normalizedDSN(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        schedule: String? = nil,
        activityCount: Int? = nil,
        lastError: String? = nil
    ) {
        RuntimeDiagnosticsCenter.shared.updateLockSchedule(
            status: status,
            dsn: dsn,
            schedule: schedule,
            activityCount: activityCount,
            lastError: lastError
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

import DeviceActivity
import Foundation
import ManagedSettings

@MainActor
final class DeviceLockScheduleMonitorController {
    typealias AuthorizationStatusAction = () -> ScreenTimePermissionStatus
    typealias StartMonitoringAction = (_ activityName: DeviceActivityName, _ schedule: DeviceActivitySchedule) throws -> Void
    typealias StopMonitoringAction = (_ activityNames: [DeviceActivityName]) -> Void
    typealias ActiveActivitiesAction = () -> [DeviceActivityName]
    typealias VoidAction = () -> Void
    typealias CurrentDateAction = () -> Date
    typealias DiagnosticsAction = (
        _ status: String?,
        _ dsn: String?,
        _ schedule: String?,
        _ activityCount: Int?,
        _ lastError: String?
    ) -> Void

    init(
        authorizationStatus: AuthorizationStatusAction? = nil,
        startMonitoring: StartMonitoringAction? = nil,
        stopMonitoring: StopMonitoringAction? = nil,
        activeActivities: ActiveActivitiesAction? = nil,
        clearMonitoringStore: VoidAction? = nil,
        currentDate: CurrentDateAction? = nil,
        diagnosticsUpdater: DiagnosticsAction? = nil
    ) {
        let activityCenter = DeviceActivityCenter()
        let scheduleStore = DeviceLockManagedSettingsStoreFactory.make(
            named: DeviceLockManagedSettingsStoreName.schedule
        )

        self.authorizationStatus = authorizationStatus ?? {
            ScreenTimeAuthorizationManager.shared.refreshStatus()
            return ScreenTimeAuthorizationManager.shared.status
        }
        self.startMonitoring = startMonitoring ?? { activityName, schedule in
            try activityCenter.startMonitoring(activityName, during: schedule)
        }
        self.stopMonitoring = stopMonitoring ?? { activityNames in
            activityCenter.stopMonitoring(activityNames)
        }
        self.activeActivities = activeActivities ?? { activityCenter.activities }
        self.clearMonitoringStore = clearMonitoringStore ?? {
            DeviceLockManagedSettingsStoreFactory.clearAllSettings(scheduleStore)
        }
        self.currentDate = currentDate ?? { Date() }
        self.diagnosticsUpdater = diagnosticsUpdater ?? { status, dsn, schedule, activityCount, lastError in
            RuntimeDiagnosticsCenter.shared.updateLockSchedule(
                status: status,
                dsn: dsn,
                schedule: schedule,
                activityCount: activityCount,
                lastError: lastError
            )
        }
    }

    func applySchedule(
        _ schedule: DeviceFullLockSchedule?,
        dsn: String?,
        referenceLocalTime: String? = nil
    ) {
        let normalizedDSN = normalizedDSN(dsn)
        let authorizationStatus = authorizationStatus()
        let configuration = makeConfiguration(
            schedule: schedule,
            dsn: normalizedDSN,
            referenceLocalTime: referenceLocalTime
        )
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
                try startMonitoring(activity.name, activity.schedule)
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

    private let authorizationStatus: AuthorizationStatusAction
    private let startMonitoring: StartMonitoringAction
    private let stopMonitoring: StopMonitoringAction
    private let activeActivities: ActiveActivitiesAction
    private let clearMonitoringStore: VoidAction
    private let currentDate: CurrentDateAction
    private let diagnosticsUpdater: DiagnosticsAction
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

    func makeConfiguration(
        schedule: DeviceFullLockSchedule?,
        dsn: String?,
        referenceLocalTime: String?
    ) -> MonitoringConfiguration? {
        guard let schedule,
              schedule.isScheduleEnabled ?? true,
              let dsn,
              let windows = monitoringWindows(
                from: schedule,
                dsn: dsn,
                referenceLocalTime: referenceLocalTime
              ),
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
        dsn: String,
        referenceLocalTime: String?
    ) -> [(String, MonitoringActivity)]? {
        guard let startMinutes = parseMinutes(schedule.startTime),
              let endMinutes = parseMinutes(schedule.endTime) else {
            return nil
        }

        let translatedWindow = translatedScheduleWindow(
            startMinutes: startMinutes,
            endMinutes: endMinutes,
            referenceLocalTime: referenceLocalTime
        )
        let translatedStartMinutes = translatedWindow.startMinutes
        let translatedEndMinutes = translatedWindow.endMinutes

        if translatedStartMinutes == translatedEndMinutes {
            guard let activity = makeActivity(
                dsn: dsn,
                suffix: "always",
                startMinutes: 0,
                endMinutes: (23 * 60) + 59
            ) else {
                return nil
            }
            return [("0-1439", activity)]
        }

        if translatedStartMinutes < translatedEndMinutes {
            guard let activity = makeActivity(
                dsn: dsn,
                suffix: "primary",
                startMinutes: translatedStartMinutes,
                endMinutes: translatedEndMinutes
            ) else {
                return nil
            }
            return [("\(translatedStartMinutes)-\(translatedEndMinutes)", activity)]
        }

        var windows: [(String, MonitoringActivity)] = []

        if let lateWindow = makeActivity(
            dsn: dsn,
            suffix: "late",
            startMinutes: translatedStartMinutes,
            endMinutes: (23 * 60) + 59
        ) {
            windows.append(("\(translatedStartMinutes)-1439", lateWindow))
        }

        if let earlyWindow = makeActivity(
            dsn: dsn,
            suffix: "early",
            startMinutes: 0,
            endMinutes: translatedEndMinutes
        ) {
            windows.append(("0-\(translatedEndMinutes)", earlyWindow))
        }

        return windows.isEmpty ? nil : windows
    }

    func translatedScheduleWindow(
        startMinutes: Int,
        endMinutes: Int,
        referenceLocalTime: String?
    ) -> (startMinutes: Int, endMinutes: Int) {
        guard let backendCurrentMinutes = parseMinutes(referenceLocalTime) else {
            return (startMinutes, endMinutes)
        }

        let deviceCurrentMinutes = minutesSinceMidnight(for: currentDate())
        let offsetMinutes = signedMinuteDifference(
            from: deviceCurrentMinutes,
            to: backendCurrentMinutes
        )

        return (
            normalizeMinutes(startMinutes - offsetMinutes),
            normalizeMinutes(endMinutes - offsetMinutes)
        )
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

    func minutesSinceMidnight(for date: Date) -> Int {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        return (hour * 60) + minute
    }

    func signedMinuteDifference(from current: Int, to target: Int) -> Int {
        var difference = target - current
        if difference > 720 {
            difference -= 1440
        } else if difference < -720 {
            difference += 1440
        }
        return difference
    }

    func normalizeMinutes(_ value: Int) -> Int {
        let normalized = value % 1440
        return normalized >= 0 ? normalized : normalized + 1440
    }

    func timeComponents(from minutes: Int) -> DateComponents {
        DateComponents(hour: minutes / 60, minute: minutes % 60)
    }

    func stopCurrentMonitoring() {
        // Reconcile against the OS: DeviceActivityCenter registrations persist across process death,
        // so stopping only the in-memory `currentActivities` orphaned any activity registered by a
        // prior process (or started before a mid-loop failure in applySchedule). Stop every
        // registered schedule activity, regardless of in-memory tracking.
        let orphaned = activeActivities().filter {
            DeviceLockScheduleActivityIdentifier.isScheduleActivity(rawValue: $0.rawValue)
        }
        let toStop = Array(Set(currentActivities).union(orphaned))
        if !toStop.isEmpty {
            stopMonitoring(toStop)
        }
        currentActivities = []
        currentSignature = nil
        clearMonitoringStore()
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
        diagnosticsUpdater(
            status,
            dsn,
            schedule,
            activityCount,
            lastError
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

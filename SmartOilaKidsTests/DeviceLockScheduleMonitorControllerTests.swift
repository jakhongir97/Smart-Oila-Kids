import DeviceActivity
import XCTest
@testable import SmartOilaKids

@MainActor
final class DeviceLockScheduleMonitorControllerTests: XCTestCase {
    func testApplyScheduleStartsSingleWindowAndDeduplicatesSignature() throws {
        var startedActivities: [(DeviceActivityName, DeviceActivitySchedule)] = []
        var diagnostics: [ScheduleDiagnostics] = []
        var clearStoreCount = 0

        let controller = makeController(
            startMonitoring: { activityName, schedule in
                startedActivities.append((activityName, schedule))
            },
            clearMonitoringStore: {
                clearStoreCount += 1
            },
            diagnosticsUpdater: { status, dsn, schedule, activityCount, lastError in
                diagnostics.append(
                    ScheduleDiagnostics(
                        status: status,
                        dsn: dsn,
                        schedule: schedule,
                        activityCount: activityCount,
                        lastError: lastError
                    )
                )
            }
        )

        let schedule = try makeSchedule(start: "08:30:00", end: "10:15:00", enabled: true)

        controller.applySchedule(schedule, dsn: " child-1 ")
        controller.applySchedule(schedule, dsn: " child-1 ")

        XCTAssertEqual(startedActivities.count, 1)
        XCTAssertEqual(
            startedActivities.first?.0.rawValue,
            DeviceLockScheduleActivityIdentifier.rawValue(dsn: "child-1", suffix: "primary")
        )
        XCTAssertEqual(startedActivities.first?.1.intervalStart.hour, 8)
        XCTAssertEqual(startedActivities.first?.1.intervalStart.minute, 30)
        XCTAssertEqual(startedActivities.first?.1.intervalEnd.hour, 10)
        XCTAssertEqual(startedActivities.first?.1.intervalEnd.minute, 15)
        XCTAssertEqual(clearStoreCount, 1)
        XCTAssertEqual(diagnostics.last?.status, "monitoring")
        XCTAssertEqual(diagnostics.last?.dsn, "child-1")
        XCTAssertEqual(diagnostics.last?.schedule, "08:30 - 10:15")
        XCTAssertEqual(diagnostics.last?.activityCount, 1)
    }

    func testApplyScheduleSplitsOvernightScheduleIntoLateAndEarlyWindows() throws {
        var startedActivities: [(DeviceActivityName, DeviceActivitySchedule)] = []
        var diagnostics: [ScheduleDiagnostics] = []

        let controller = makeController(
            startMonitoring: { activityName, schedule in
                startedActivities.append((activityName, schedule))
            },
            clearMonitoringStore: {},
            diagnosticsUpdater: { status, dsn, schedule, activityCount, lastError in
                diagnostics.append(
                    ScheduleDiagnostics(
                        status: status,
                        dsn: dsn,
                        schedule: schedule,
                        activityCount: activityCount,
                        lastError: lastError
                    )
                )
            }
        )

        let schedule = try makeSchedule(start: "22:30:00", end: "06:45:00", enabled: true)

        controller.applySchedule(schedule, dsn: "child-night")

        XCTAssertEqual(
            startedActivities.map(\.0.rawValue),
            [
                DeviceLockScheduleActivityIdentifier.rawValue(dsn: "child-night", suffix: "late"),
                DeviceLockScheduleActivityIdentifier.rawValue(dsn: "child-night", suffix: "early")
            ]
        )
        XCTAssertEqual(startedActivities.map { $0.1.intervalStart.hour }, [22, 0])
        XCTAssertEqual(startedActivities.map { $0.1.intervalStart.minute }, [30, 0])
        XCTAssertEqual(startedActivities.map { $0.1.intervalEnd.hour }, [23, 6])
        XCTAssertEqual(startedActivities.map { $0.1.intervalEnd.minute }, [59, 45])
        XCTAssertEqual(diagnostics.last?.status, "monitoring")
        XCTAssertEqual(diagnostics.last?.activityCount, 2)
        XCTAssertEqual(diagnostics.last?.schedule, "22:30 - 06:45")
    }

    func testApplyScheduleTreatsEqualStartAndEndAsAllDayLock() throws {
        var startedActivities: [(DeviceActivityName, DeviceActivitySchedule)] = []
        var diagnostics: [ScheduleDiagnostics] = []

        let controller = makeController(
            startMonitoring: { activityName, schedule in
                startedActivities.append((activityName, schedule))
            },
            clearMonitoringStore: {},
            diagnosticsUpdater: { status, dsn, schedule, activityCount, lastError in
                diagnostics.append(
                    ScheduleDiagnostics(
                        status: status,
                        dsn: dsn,
                        schedule: schedule,
                        activityCount: activityCount,
                        lastError: lastError
                    )
                )
            }
        )

        let schedule = try makeSchedule(start: "00:00:00", end: "00:00:00", enabled: true)

        controller.applySchedule(schedule, dsn: "child-always")

        XCTAssertEqual(startedActivities.count, 1)
        XCTAssertEqual(
            startedActivities.first?.0.rawValue,
            DeviceLockScheduleActivityIdentifier.rawValue(dsn: "child-always", suffix: "always")
        )
        XCTAssertEqual(startedActivities.first?.1.intervalStart.hour, 0)
        XCTAssertEqual(startedActivities.first?.1.intervalStart.minute, 0)
        XCTAssertEqual(startedActivities.first?.1.intervalEnd.hour, 23)
        XCTAssertEqual(startedActivities.first?.1.intervalEnd.minute, 59)
        XCTAssertEqual(diagnostics.last?.status, "monitoring")
        XCTAssertEqual(diagnostics.last?.dsn, "child-always")
        XCTAssertEqual(diagnostics.last?.schedule, "00:00 - 00:00")
        XCTAssertEqual(diagnostics.last?.activityCount, 1)
    }

    func testApplyScheduleWithoutAuthorizationSkipsMonitoringAndReportsUnavailable() throws {
        var startedActivities: [(DeviceActivityName, DeviceActivitySchedule)] = []
        var diagnostics: [ScheduleDiagnostics] = []
        var clearStoreCount = 0

        let controller = makeController(
            authorizationStatus: { .unavailable },
            startMonitoring: { activityName, schedule in
                startedActivities.append((activityName, schedule))
            },
            clearMonitoringStore: {
                clearStoreCount += 1
            },
            diagnosticsUpdater: { status, dsn, schedule, activityCount, lastError in
                diagnostics.append(
                    ScheduleDiagnostics(
                        status: status,
                        dsn: dsn,
                        schedule: schedule,
                        activityCount: activityCount,
                        lastError: lastError
                    )
                )
            }
        )

        let schedule = try makeSchedule(start: "08:30:00", end: "10:15:00", enabled: true)

        controller.applySchedule(schedule, dsn: "child-blocked")

        XCTAssertTrue(startedActivities.isEmpty)
        XCTAssertEqual(clearStoreCount, 1)
        XCTAssertEqual(diagnostics.last?.status, "unavailable")
        XCTAssertEqual(diagnostics.last?.dsn, "child-blocked")
        XCTAssertEqual(diagnostics.last?.schedule, "08:30 - 10:15")
        XCTAssertEqual(diagnostics.last?.activityCount, 0)
    }

    func testStopCancelsCurrentActivitiesAndReportsIdle() throws {
        var startedActivities: [(DeviceActivityName, DeviceActivitySchedule)] = []
        var stoppedActivityBatches: [[DeviceActivityName]] = []
        var diagnostics: [ScheduleDiagnostics] = []
        var clearStoreCount = 0

        let controller = makeController(
            startMonitoring: { activityName, schedule in
                startedActivities.append((activityName, schedule))
            },
            stopMonitoring: { activityNames in
                stoppedActivityBatches.append(activityNames)
            },
            clearMonitoringStore: {
                clearStoreCount += 1
            },
            diagnosticsUpdater: { status, dsn, schedule, activityCount, lastError in
                diagnostics.append(
                    ScheduleDiagnostics(
                        status: status,
                        dsn: dsn,
                        schedule: schedule,
                        activityCount: activityCount,
                        lastError: lastError
                    )
                )
            }
        )

        let schedule = try makeSchedule(start: "08:30:00", end: "10:15:00", enabled: true)

        controller.applySchedule(schedule, dsn: "child-stop")
        controller.stop()

        XCTAssertEqual(startedActivities.count, 1)
        XCTAssertEqual(stoppedActivityBatches.count, 1)
        XCTAssertEqual(
            stoppedActivityBatches.first?.map(\.rawValue),
            [DeviceLockScheduleActivityIdentifier.rawValue(dsn: "child-stop", suffix: "primary")]
        )
        XCTAssertEqual(clearStoreCount, 2)
        XCTAssertEqual(diagnostics.last?.status, "idle")
        XCTAssertEqual(diagnostics.last?.dsn, "-")
        XCTAssertEqual(diagnostics.last?.schedule, "-")
        XCTAssertEqual(diagnostics.last?.activityCount, 0)
    }

    private func makeController(
        authorizationStatus: DeviceLockScheduleMonitorController.AuthorizationStatusAction? = nil,
        startMonitoring: DeviceLockScheduleMonitorController.StartMonitoringAction? = nil,
        stopMonitoring: DeviceLockScheduleMonitorController.StopMonitoringAction? = nil,
        clearMonitoringStore: DeviceLockScheduleMonitorController.VoidAction? = nil,
        diagnosticsUpdater: DeviceLockScheduleMonitorController.DiagnosticsAction? = nil
    ) -> DeviceLockScheduleMonitorController {
        DeviceLockScheduleMonitorController(
            authorizationStatus: authorizationStatus ?? { .granted },
            startMonitoring: startMonitoring ?? { _, _ in },
            stopMonitoring: stopMonitoring ?? { _ in },
            clearMonitoringStore: clearMonitoringStore ?? {},
            diagnosticsUpdater: diagnosticsUpdater ?? { _, _, _, _, _ in }
        )
    }

    private func makeSchedule(start: String, end: String, enabled: Bool) throws -> DeviceFullLockSchedule {
        let payload = """
        {
          "start_time": "\(start)",
          "end_time": "\(end)",
          "is_schedule_enabled": \(enabled)
        }
        """
        return try JSONDecoder().decode(DeviceFullLockSchedule.self, from: Data(payload.utf8))
    }
}

private struct ScheduleDiagnostics: Equatable {
    let status: String?
    let dsn: String?
    let schedule: String?
    let activityCount: Int?
    let lastError: String?
}

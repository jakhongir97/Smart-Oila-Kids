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

    func testApplyScheduleTranslatesBackendScheduleIntoDeviceLocalTime() throws {
        var startedActivities: [(DeviceActivityName, DeviceActivitySchedule)] = []

        let currentDate = try XCTUnwrap(
            Calendar.autoupdatingCurrent.date(
                from: DateComponents(year: 2026, month: 1, day: 1, hour: 17, minute: 30)
            )
        )
        let controller = makeController(
            startMonitoring: { activityName, schedule in
                startedActivities.append((activityName, schedule))
            },
            clearMonitoringStore: {},
            currentDate: { currentDate }
        )

        let schedule = try makeSchedule(start: "22:30:00", end: "06:45:00", enabled: true)

        controller.applySchedule(
            schedule,
            dsn: "child-translated",
            referenceLocalTime: "22:30:00"
        )

        XCTAssertEqual(
            startedActivities.map(\.0.rawValue),
            [
                DeviceLockScheduleActivityIdentifier.rawValue(dsn: "child-translated", suffix: "late"),
                DeviceLockScheduleActivityIdentifier.rawValue(dsn: "child-translated", suffix: "early")
            ]
        )
        XCTAssertEqual(startedActivities.map { $0.1.intervalStart.hour }, [17, 0])
        XCTAssertEqual(startedActivities.map { $0.1.intervalStart.minute }, [30, 0])
        XCTAssertEqual(startedActivities.map { $0.1.intervalEnd.hour }, [23, 1])
        XCTAssertEqual(startedActivities.map { $0.1.intervalEnd.minute }, [59, 45])
    }

    func testApplyScheduleTreatsZeroLengthWindowAsNoLock() throws {
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

        // A zero-length window registers NOTHING.
        //
        // This previously asserted the opposite -- that start == end was promoted to a 00:00-23:59
        // all-day lock. That is an unsafe reading of an ambiguous input: `CreateLockScheduleDto`
        // puts an independent `minimum: 0, maximum: 1439` on startMinute and endMinute with NO
        // cross-field constraint, so a parent-side picker defaulting both to the same value produces
        // a body the backend accepts -- and the child was then locked around the clock while the
        // parent saw what looked like an inert row.
        //
        // For a parental control, the safe reading of an ambiguous window is the one that does not
        // lock a child indefinitely. If the backend ever defines zero-length as all-day it has to
        // send 0...1439 explicitly.
        XCTAssertEqual(startedActivities.count, 0)
        XCTAssertEqual(diagnostics.last?.status, "disabled")
        XCTAssertEqual(diagnostics.last?.dsn, "child-always")
        XCTAssertEqual(diagnostics.last?.activityCount, 0)
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
        currentDate: DeviceLockScheduleMonitorController.CurrentDateAction? = nil,
        diagnosticsUpdater: DeviceLockScheduleMonitorController.DiagnosticsAction? = nil
    ) -> DeviceLockScheduleMonitorController {
        DeviceLockScheduleMonitorController(
            authorizationStatus: authorizationStatus ?? { .granted },
            startMonitoring: startMonitoring ?? { _, _ in },
            stopMonitoring: stopMonitoring ?? { _ in },
            clearMonitoringStore: clearMonitoringStore ?? {},
            currentDate: currentDate,
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

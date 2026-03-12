import Foundation

extension MainViewModel {
    func loadWeeklyUsage(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            resetForMissingDSN()
            return
        }

        guard !usagePhase.isLoading else { return }
        setUsagePhase(.loading)

        let statusTask = Task { [dashboardService = dependencies.dashboardService] in
            try? await dashboardService.fetchDeviceStatus(dsn: dsn)
        }
        let pendingTasksTask = Task<Int?, Never> {
            if let remote = try? await dependencies.taskSummaryService.fetchPendingTasksCount(dsn: dsn) {
                return remote
            }

            let cachedAwards = dependencies.taskCacheStore.load(for: dsn)
            guard !cachedAwards.isEmpty else { return nil }
            return Self.computePendingTasksCount(from: cachedAwards)
        }

        await loadUsageHours(dsn: dsn)
        await resolveDeviceNameAndStatus(dsn: dsn, statusTask: statusTask)
        setPendingTasksCount(await pendingTasksTask.value)

        await refreshUnreadChat(dsn: dsn)
        await refreshUnreadNotifications(dsn: dsn)
        await refreshDeviceControlTimeline(dsn: dsn)
        await refreshMediaTimeline(dsn: dsn)
    }
}

private extension MainViewModel {
    func resetForMissingDSN() {
        setCurrentDeviceName(nil)
        setDeviceStatus(nil)
        setPendingTasksCount(nil)
        setUnreadChatCount(nil)
        setUnreadNotificationCount(0)
        setRecentDeviceControlItems([])
        setRecentMediaItems([])
        setUsagePhase(.failed(L10n.tr("common.dsn_missing")))
    }

    func loadUsageHours(dsn: String) async {
        do {
            let usage = try await dependencies.dashboardService.fetchWeeklyUsageHours(dsn: dsn)
            setWeeklyUsageHours(usage)
            setUsagePhase(.loaded)
        } catch let NetworkError.server(statusCode, _) where statusCode == 401 || statusCode == 403 {
            // DSN-only mode: backend does not grant member scope yet.
            setWeeklyUsageHours(Array(repeating: 0, count: 7))
            setUsagePhase(.loaded)
        } catch NetworkError.unexpectedBody {
            // Device cannot be resolved via member endpoints; keep dashboard usable.
            setWeeklyUsageHours(Array(repeating: 0, count: 7))
            setUsagePhase(.loaded)
        } catch {
            setUsagePhase(.failed(NetworkError.userMessage(for: error)))
        }
    }

    func resolveDeviceNameAndStatus(
        dsn: String,
        statusTask: Task<MainDeviceStatus?, Never>
    ) async {
        if let status = await statusTask.value {
            setDeviceStatus(status)
            let resolvedName = status.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolvedName.isEmpty {
                setCurrentDeviceName(resolvedName)
            }
            return
        }

        setDeviceStatus(nil)
        if let resolvedName = try? await dependencies.dashboardService.fetchCurrentDeviceName(dsn: dsn),
           !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setCurrentDeviceName(resolvedName)
        }
    }
}

import SwiftUI

private struct PaginatedDeviceRecordingTaskResponse: Decodable {
    let pageNextNumber: Int?
    let pagePrevNumber: Int?
    let data: [DeviceRecordingTaskResponse]?

    enum CodingKeys: String, CodingKey {
        case pageNextNumber = "page_next_number"
        case pagePrevNumber = "page_prev_number"
        case data
    }
}

private final class DeviceRecordingHistoryService {
    init(
        client: APIClient = APIClient(),
        uploadService: DeviceRecordingUploadService = DeviceRecordingUploadService()
    ) {
        self.client = client
        self.uploadService = uploadService
    }

    func fetchRecordings(dsn: String, page: Int = 1, limit: Int = 10) async throws -> [DeviceRecordingTaskResponse] {
        let response = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/recordings/",
            method: .get,
            queryItems: [
                URLQueryItem(name: "device_dsn", value: dsn),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ],
            headers: ["Accept": "application/json"],
            as: PaginatedDeviceRecordingTaskResponse.self
        )

        return response.data ?? []
    }

    func deleteRecording(id: Int) async throws {
        _ = try await uploadService.deleteRecording(recordingID: "\(id)")
    }

    private let client: APIClient
    private let uploadService: DeviceRecordingUploadService
}

@MainActor
private final class SettingsMediaHistoryViewModel: ObservableObject {
    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var recordings: [DeviceRecordingTaskResponse] = []
    @Published private(set) var activityEvents: [MediaActivityEvent] = []
    @Published private(set) var pendingActionCount = 0
    @Published private(set) var deletingIDs: Set<Int> = []
    @Published private(set) var previewLoadingID: Int?
    @Published private(set) var previewItem: DeviceRecordingPreviewItem?
    @Published private(set) var previewErrorMessage: String?
    @Published private(set) var lastErrorMessage: String?

    init(
        service: DeviceRecordingHistoryService = DeviceRecordingHistoryService(),
        previewService: DeviceRecordingPreviewService = DeviceRecordingPreviewService()
    ) {
        self.service = service
        self.previewService = previewService
    }

    func load(dsn: String?) async {
        guard let normalizedDSN = dsn?.trimmedNonEmpty else {
            recordings = []
            activityEvents = []
            pendingActionCount = 0
            phase = .idle
            lastErrorMessage = nil
            return
        }

        currentDSN = normalizedDSN
        phase = .loading
        lastErrorMessage = nil

        async let localActivity = MediaTelemetryNotifier.shared.loadEvents(dsn: normalizedDSN, limit: 24)
        async let pendingActions = DeviceRecordingTransportCoordinator.shared.pendingActionCount()

        let activity = await localActivity
        let pendingCount = await pendingActions
        activityEvents = activity
        pendingActionCount = pendingCount

        do {
            let fetched = try await service.fetchRecordings(dsn: normalizedDSN)
            recordings = sortRecordings(fetched)
            phase = .loaded
        } catch {
            recordings = []
            lastErrorMessage = NetworkError.userMessage(for: error)
            phase = (!activity.isEmpty || pendingCount > 0) ? .loaded : .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        await load(dsn: currentDSN)
    }

    func openPreview(for recording: DeviceRecordingTaskResponse) async {
        guard previewLoadingID != recording.id else { return }

        previewLoadingID = recording.id
        previewErrorMessage = nil

        defer {
            previewLoadingID = nil
        }

        do {
            previewItem = try await previewService.preparePreview(for: recording)
        } catch {
            previewErrorMessage = NetworkError.userMessage(for: error)
        }
    }

    func dismissPreview() {
        previewItem = nil
    }

    func retryPendingActions() async {
        await DeviceRecordingTransportCoordinator.shared.retryNow()
        await load(dsn: currentDSN)
    }

    func delete(_ recording: DeviceRecordingTaskResponse) async {
        guard deletingIDs.contains(recording.id) == false else { return }
        deletingIDs.insert(recording.id)
        defer { deletingIDs.remove(recording.id) }

        do {
            try await service.deleteRecording(id: recording.id)
            recordings.removeAll { $0.id == recording.id }
        } catch {
            lastErrorMessage = NetworkError.userMessage(for: error)
        }
    }

    private func sortRecordings(_ recordings: [DeviceRecordingTaskResponse]) -> [DeviceRecordingTaskResponse] {
        recordings.sorted { lhs, rhs in
            let leftDate = Self.timestampFormatter.date(from: lhs.createdAt) ?? .distantPast
            let rightDate = Self.timestampFormatter.date(from: rhs.createdAt) ?? .distantPast
            return leftDate > rightDate
        }
    }

    private let service: DeviceRecordingHistoryService
    private let previewService: DeviceRecordingPreviewService
    private var currentDSN: String?

    private static let timestampFormatter = ISO8601DateFormatter()
}

struct SettingsMediaHistoryPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore

    @ObservedObject var manager: LocationPermissionManager
    @StateObject private var viewModel = SettingsMediaHistoryViewModel()

    var body: some View {
        AppNavigationContainer {
            Group {
                switch viewModel.phase {
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    failedState
                case .loaded:
                    loadedState
                }
            }
            .background(AppColors.white.ignoresSafeArea())
            .navigationTitle(L10n.tr("settings.media_history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.tr("common.close")) {
                        dismiss()
                    }
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            await viewModel.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppColors.primaryPurple)
                    }
                }
            }
            .task {
                manager.refreshStatuses()
                await viewModel.load(dsn: sessionStore.dsn)
            }
            .onChange(of: sessionStore.dsn) { newValue in
                Task {
                    await viewModel.load(dsn: newValue)
                }
            }
        }
        .sheet(
            item: Binding(
                get: { viewModel.previewItem },
                set: { newValue in
                    if newValue == nil {
                        viewModel.dismissPreview()
                    }
                }
            )
        ) { preview in
            SettingsMediaRecordingPreviewSheet(preview: preview)
        }
    }

    private var failedState: some View {
        VStack(spacing: 14) {
            SettingsMediaReadinessSummaryCard(manager: manager)

            Text(L10n.tr("settings.media_history_load_failed"))
                .font(AppTypography.unbounded(13, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            if let lastErrorMessage = viewModel.lastErrorMessage?.trimmedNonEmpty {
                Text(lastErrorMessage)
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button(L10n.tr("common.retry")) {
                Task {
                    await viewModel.refresh()
                }
            }
            .font(AppTypography.unbounded(12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(AppColors.primaryPurple)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadedState: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsMediaReadinessSummaryCard(manager: manager)

                if let lastErrorMessage = viewModel.lastErrorMessage?.trimmedNonEmpty {
                    Text(lastErrorMessage)
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.dangerRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let previewErrorMessage = viewModel.previewErrorMessage?.trimmedNonEmpty {
                    Text(previewErrorMessage)
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.dangerRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.pendingActionCount > 0 {
                    pendingActionsCard
                }

                if !viewModel.activityEvents.isEmpty {
                    sectionHeader(L10n.tr("settings.media_history_activity_title"))
                    ForEach(viewModel.activityEvents) { event in
                        activityCard(event)
                    }
                }

                if !viewModel.recordings.isEmpty {
                    sectionHeader(L10n.tr("settings.media_history_recordings_title"))
                    ForEach(viewModel.recordings, id: \.id) { recording in
                        recordingCard(recording)
                    }
                }

                if viewModel.recordings.isEmpty && viewModel.activityEvents.isEmpty && viewModel.pendingActionCount == 0 {
                    Text(L10n.tr("settings.media_history_empty"))
                        .font(AppTypography.unbounded(12, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    private var pendingActionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("settings.media_history_pending_uploads", "\(viewModel.pendingActionCount)"))
                .font(AppTypography.unbounded(11, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            Button(L10n.tr("settings.media_history_retry_pending")) {
                Task {
                    await viewModel.retryPendingActions()
                }
            }
            .font(AppTypography.unbounded(11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(AppColors.primaryPurple)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColors.primaryPurple.opacity(0.12), lineWidth: 1)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.unbounded(11, weight: .semibold))
            .foregroundStyle(AppColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityCard(_ event: MediaActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(mediaTypeTitle(event.mediaType), systemImage: mediaTypeIcon(event.mediaType))
                    .font(AppTypography.unbounded(11, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)

                Spacer(minLength: 12)

                Text(activityTitle(event.event))
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(activityAccentColor(event.event))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(activityAccentColor(event.event).opacity(0.12))
                    .clipShape(Capsule())
            }

            Text(formattedTimestamp(event.createdAt))
                .font(AppTypography.unbounded(10, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)

            if let recordingID = event.recordingID?.trimmedNonEmpty {
                Text("ID: \(recordingID)")
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
            }

            if let reason = event.reason?.trimmedNonEmpty {
                Text(reason)
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColors.primaryPurple.opacity(0.12), lineWidth: 1)
        }
    }

    private func recordingCard(_ recording: DeviceRecordingTaskResponse) -> some View {
        let isDeleting = viewModel.deletingIDs.contains(recording.id)
        let isPreparingPreview = viewModel.previewLoadingID == recording.id

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(typeTitle(recording.type), systemImage: typeIcon(recording.type))
                    .font(AppTypography.unbounded(12, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)

                Spacer(minLength: 12)

                Text(statusTitle(recording.status))
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(recording.status == .completed ? AppColors.primaryPurple : AppColors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppColors.primaryPurple.opacity(recording.status == .completed ? 0.12 : 0.08))
                    .clipShape(Capsule())
            }

            Text(formattedTimestamp(recording.createdAt))
                .font(AppTypography.unbounded(10, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)

            if recording.status == .completed {
                Button {
                    Task {
                        await viewModel.openPreview(for: recording)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isPreparingPreview {
                            ProgressView()
                                .tint(AppColors.primaryPurple)
                        } else {
                            Image(systemName: "play.rectangle")
                        }

                        Text(
                            isPreparingPreview
                                ? L10n.tr("settings.media_history_preview_loading")
                                : L10n.tr("settings.media_history_preview")
                        )
                    }
                    .font(AppTypography.unbounded(11, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }
                .disabled(isPreparingPreview)
            }

            Button(role: .destructive) {
                Task {
                    await viewModel.delete(recording)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text(L10n.tr("settings.media_history_delete"))
                }
                .font(AppTypography.unbounded(11, weight: .medium))
            }
            .disabled(isDeleting)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColors.primaryPurple.opacity(0.12), lineWidth: 1)
        }
        .opacity(isDeleting ? 0.6 : 1)
    }

    private func activityTitle(_ event: MediaTelemetryEvent) -> String {
        switch event {
        case .recordingStarted:
            return L10n.tr("settings.media_history_activity_recording_started")
        case .recordingCompleted:
            return L10n.tr("settings.media_history_activity_recording_completed")
        case .recordingUploadQueued:
            return L10n.tr("settings.media_history_activity_recording_upload_queued")
        case .recordingDiscarded:
            return L10n.tr("settings.media_history_activity_recording_discarded")
        case .recordingFailed:
            return L10n.tr("settings.media_history_activity_recording_failed")
        case .recordingCancelled:
            return L10n.tr("settings.media_history_activity_recording_cancelled")
        case .streamStarted:
            return L10n.tr("settings.media_history_activity_stream_started")
        case .streamStopped:
            return L10n.tr("settings.media_history_activity_stream_stopped")
        case .streamFailed:
            return L10n.tr("settings.media_history_activity_stream_failed")
        case .streamDeliveryFailed:
            return L10n.tr("settings.media_history_activity_stream_delivery_failed")
        case .permissionRevoked:
            return L10n.tr("settings.media_history_activity_permission_revoked")
        case .foregroundInterrupted:
            return L10n.tr("settings.media_history_activity_foreground_interrupted")
        }
    }

    private func activityAccentColor(_ event: MediaTelemetryEvent) -> Color {
        switch event {
        case .recordingCompleted, .streamStarted:
            return AppColors.primaryPurple
        case .recordingUploadQueued, .recordingDiscarded, .recordingCancelled, .streamStopped:
            return AppColors.textSecondary
        case .recordingStarted:
            return AppColors.primaryPurple
        case .recordingFailed, .streamFailed, .streamDeliveryFailed, .permissionRevoked, .foregroundInterrupted:
            return AppColors.dangerRed
        }
    }

    private func mediaTypeTitle(_ type: MediaTelemetryType) -> String {
        switch type {
        case .environment:
            return L10n.tr("settings.media_history_type_environment")
        case .camera:
            return L10n.tr("settings.media_history_type_camera")
        case .display:
            return L10n.tr("settings.media_history_type_display")
        case .audioStream:
            return L10n.tr("settings.media_history_type_audio_stream")
        case .cameraStream:
            return L10n.tr("settings.media_history_type_camera_stream")
        case .frontCameraStream:
            return L10n.tr("settings.media_history_type_front_camera_stream")
        }
    }

    private func mediaTypeIcon(_ type: MediaTelemetryType) -> String {
        switch type {
        case .environment:
            return "waveform.circle.fill"
        case .camera:
            return "camera.fill"
        case .display:
            return "rectangle.on.rectangle"
        case .audioStream:
            return "waveform"
        case .cameraStream:
            return "video"
        case .frontCameraStream:
            return "video.circle"
        }
    }

    private func typeTitle(_ type: DeviceRecordingTaskType) -> String {
        switch type {
        case .camera:
            return L10n.tr("settings.media_history_type_camera")
        case .display:
            return L10n.tr("settings.media_history_type_display")
        case .environment:
            return L10n.tr("settings.media_history_type_environment")
        }
    }

    private func typeIcon(_ type: DeviceRecordingTaskType) -> String {
        switch type {
        case .camera:
            return "camera.fill"
        case .display:
            return "rectangle.on.rectangle"
        case .environment:
            return "waveform.circle.fill"
        }
    }

    private func statusTitle(_ status: DeviceRecordingTaskStatus) -> String {
        switch status {
        case .completed:
            return L10n.tr("settings.media_history_status_completed")
        case .inProgress:
            return L10n.tr("settings.media_history_status_in_progress")
        }
    }

    private func formattedTimestamp(_ value: String) -> String {
        guard let date = Self.timestampFormatter.date(from: value) else { return value }
        return Self.displayFormatter.string(from: date)
    }

    private func formattedTimestamp(_ date: Date) -> String {
        Self.displayFormatter.string(from: date)
    }

    private static let timestampFormatter = ISO8601DateFormatter()
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct SettingsMediaReadinessSummaryCard: View {
    @ObservedObject var manager: LocationPermissionManager

    var body: some View {
        let isReady = manager.mediaReadinessSatisfied
        let accentColor = isReady ? AppColors.accentGreen : AppColors.dangerRed

        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("permissions.media_readiness_title"))
                .font(AppTypography.unbounded(12, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            Text(manager.mediaReadinessMessage())
                .font(AppTypography.unbounded(10, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                .lineSpacing(2)

            VStack(spacing: 8) {
                ForEach(manager.mediaCapabilityStatuses) { capability in
                    capabilityRow(capability)
                }
            }
            .padding(.top, 2)

            Text(
                isReady
                    ? L10n.tr("permissions.media_readiness_status_ready")
                    : L10n.tr("permissions.media_readiness_status_incomplete")
            )
            .font(AppTypography.unbounded(10, weight: .semibold))
            .foregroundStyle(accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(accentColor.opacity(0.12))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColor.opacity(0.35), lineWidth: 2)
        }
    }

    private func capabilityRow(_ capability: MediaCapabilityStatus) -> some View {
        let accentColor: Color
        switch capability.state {
        case .ready:
            accentColor = AppColors.accentGreen
        case .inactive:
            accentColor = AppColors.primaryPurple
        case .actionNeeded, .unavailable:
            accentColor = AppColors.dangerRed
        }

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(capability.title)
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)

                Text(capability.detail)
                    .font(AppTypography.unbounded(9, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 8)

            Text(capability.badgeText)
                .font(AppTypography.unbounded(8, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(accentColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(AppColors.white.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

import AVKit
import SwiftUI

struct DeviceRecordingPreviewItem: Identifiable, Equatable {
    let recording: DeviceRecordingTaskResponse
    let fileURL: URL

    var id: Int { recording.id }
}

enum DeviceRecordingPreviewError: LocalizedError {
    case missingRemoteURL
    case invalidResponse
    case failedToStore

    var errorDescription: String? {
        switch self {
        case .missingRemoteURL:
            return L10n.tr("settings.media_history_preview_missing")
        case .invalidResponse:
            return L10n.tr("error.invalid_response")
        case .failedToStore:
            return L10n.tr("error.request_failed")
        }
    }
}

final class DeviceRecordingPreviewService {
    init(
        session: URLSession = .shared,
        secureTokens: SecureTokenStoring = SecureTokenStore.shared,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.secureTokens = secureTokens
        self.fileManager = fileManager
    }

    func preparePreview(for recording: DeviceRecordingTaskResponse) async throws -> DeviceRecordingPreviewItem {
        guard let remoteURL = resolvedRemoteURL(for: recording) else {
            throw DeviceRecordingPreviewError.missingRemoteURL
        }

        let localURL = try cachedFileURL(for: recording, remoteURL: remoteURL)
        if fileManager.fileExists(atPath: localURL.path) {
            return DeviceRecordingPreviewItem(recording: recording, fileURL: localURL)
        }

        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let authorization = secureTokens.accessToken()?.trimmedNonEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            throw NetworkError.underlying(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeviceRecordingPreviewError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw NetworkError.server(statusCode: httpResponse.statusCode, body: "")
        }

        let parentDirectory = localURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: localURL.path) {
            try? fileManager.removeItem(at: localURL)
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: localURL)
        } catch {
            throw DeviceRecordingPreviewError.failedToStore
        }

        return DeviceRecordingPreviewItem(recording: recording, fileURL: localURL)
    }

    private let session: URLSession
    private let secureTokens: SecureTokenStoring
    private let fileManager: FileManager
}

private extension DeviceRecordingPreviewService {
    func resolvedRemoteURL(for recording: DeviceRecordingTaskResponse) -> URL? {
        guard let rawURL = recording.url?.trimmedNonEmpty else { return nil }

        if let absoluteURL = URL(string: rawURL), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard let hostBaseURL = hostBaseURL() else { return nil }

        if rawURL.hasPrefix("/") {
            return URL(string: rawURL, relativeTo: hostBaseURL)?.absoluteURL
        }

        return URL(string: rawURL, relativeTo: AppConfig.apiBaseURL)?.absoluteURL
            ?? URL(string: rawURL, relativeTo: hostBaseURL)?.absoluteURL
    }

    func cachedFileURL(for recording: DeviceRecordingTaskResponse, remoteURL: URL) throws -> URL {
        let cachesDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let previewsDirectory = cachesDirectory.appendingPathComponent("MediaPreviewCache", isDirectory: true)
        let fileExtension = remoteURL.pathExtension.trimmedNonEmpty ?? defaultFileExtension(for: recording.type)
        let fileName = "recording_\(recording.id)_\(recording.type.rawValue).\(fileExtension)"
        return previewsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func defaultFileExtension(for type: DeviceRecordingTaskType) -> String {
        switch type {
        case .environment:
            return "m4a"
        case .camera, .display:
            return "mp4"
        }
    }

    func hostBaseURL() -> URL? {
        guard var components = URLComponents(url: AppConfig.apiBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct SettingsMediaRecordingPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preview: DeviceRecordingPreviewItem

    @State private var player: AVPlayer
    @State private var showShareSheet = false

    init(preview: DeviceRecordingPreviewItem) {
        self.preview = preview
        _player = State(initialValue: AVPlayer(url: preview.fileURL))
    }

    var body: some View {
        AppNavigationContainer {
            VStack(alignment: .leading, spacing: 16) {
                DeviceRecordingPlayerView(player: player)
                    .frame(minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(typeTitle(preview.recording.type))
                        .font(AppTypography.unbounded(13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)

                    Text(formattedTimestamp(preview.recording.createdAt))
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)

                    Text(preview.fileURL.lastPathComponent)
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)
                }

                Button {
                    showShareSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text(L10n.tr("settings.media_history_share"))
                    }
                    .font(AppTypography.unbounded(11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(AppColors.primaryPurple)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(AppColors.white.ignoresSafeArea())
            .navigationTitle(L10n.tr("settings.media_history_preview_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.tr("common.close")) {
                        dismiss()
                    }
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: [preview.fileURL])
        }
        .onDisappear {
            player.pause()
        }
    }
}

private struct DeviceRecordingPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

private extension SettingsMediaRecordingPreviewSheet {
    func typeTitle(_ type: DeviceRecordingTaskType) -> String {
        switch type {
        case .camera:
            return L10n.tr("settings.media_history_type_camera")
        case .display:
            return L10n.tr("settings.media_history_type_display")
        case .environment:
            return L10n.tr("settings.media_history_type_environment")
        }
    }

    func formattedTimestamp(_ value: String) -> String {
        guard let date = Self.timestampFormatter.date(from: value) else { return value }
        return Self.displayFormatter.string(from: date)
    }

    static let timestampFormatter = ISO8601DateFormatter()

    static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

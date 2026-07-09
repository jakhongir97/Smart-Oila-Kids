import Foundation

final class DeviceRecordingUploadService {
    init(oila: OilaDeviceServicing = OilaDeviceClient.shared, client: APIClient = APIClient()) {
        self.oila = oila
        self.client = client
    }

    func completeRecording(recordingID: String, fileURL: URL) async throws -> DeviceRecordingTaskResponse {
        // oila360: PUT /device/recordings/{id}/complete (multipart, device Bearer). The response
        // shape is undocumented and only `status` is consumed downstream, so map it tolerantly.
        let data = try await oila.completeRecording(
            recordingID: recordingID,
            fileURL: fileURL,
            durationSeconds: nil
        )
        return Self.mapCompletion(recordingID: recordingID, data: data)
    }

    func deleteRecording(recordingID: String) async throws -> DeviceRecordingDeleteResponse {
        // oila360 has no device-side recording delete (deletion is parent-only,
        // `DELETE /parent/recordings/{id}`), so this stays on the legacy backend.
        try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/recordings/\(recordingID)",
            method: .delete,
            headers: ["Accept": "application/json"],
            as: DeviceRecordingDeleteResponse.self
        )
    }

    private static func mapCompletion(recordingID: String, data: [String: Any]) -> DeviceRecordingTaskResponse {
        let status = (data["status"] as? String)
            .flatMap { DeviceRecordingTaskStatus(rawValue: $0.lowercased()) } ?? .completed
        let type = (data["type"] as? String)
            .flatMap { DeviceRecordingTaskType(rawValue: $0.lowercased()) } ?? .environment
        let id = (data["id"] as? Int) ?? Int(recordingID) ?? 0
        let deviceID = (data["deviceId"] as? Int) ?? (data["device_id"] as? Int) ?? 0
        let deviceDSN = (data["deviceDsn"] as? String) ?? (data["device_dsn"] as? String) ?? ""
        let url = (data["url"] as? String) ?? (data["fileUrl"] as? String)
        let createdAt = (data["createdAt"] as? String) ?? (data["created_at"] as? String) ?? ""
        return DeviceRecordingTaskResponse(
            id: id,
            deviceID: deviceID,
            deviceDSN: deviceDSN,
            type: type,
            status: status,
            url: url,
            createdAt: createdAt
        )
    }

    private let oila: OilaDeviceServicing
    private let client: APIClient
}

struct DeviceRecordingDeleteResponse: Decodable, Equatable {
    let message: String
}

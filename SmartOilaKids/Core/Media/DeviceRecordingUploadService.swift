import Foundation

final class DeviceRecordingUploadService {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func completeRecording(recordingID: String, fileURL: URL) async throws -> DeviceRecordingTaskResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = try makeMultipartBody(fileURL: fileURL, boundary: boundary)
        var lastError: Error?

        for baseURL in AppConfig.apiBaseCandidates {
            do {
                let request = try client.makeRequest(
                    baseURL: baseURL,
                    path: "devices/recordings/\(recordingID)/complete",
                    method: .put,
                    headers: ["Accept": "application/json"],
                    body: body,
                    contentType: "multipart/form-data; boundary=\(boundary)"
                )
                return try await client.requestDecodable(request, as: DeviceRecordingTaskResponse.self)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NetworkError.invalidURL
    }

    func deleteRecording(recordingID: String) async throws -> DeviceRecordingDeleteResponse {
        try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/recordings/\(recordingID)",
            method: .delete,
            headers: ["Accept": "application/json"],
            as: DeviceRecordingDeleteResponse.self
        )
    }

    private let client: APIClient

    private func makeMultipartBody(fileURL: URL, boundary: String) throws -> Data {
        let fileData = try Data(contentsOf: fileURL)
        let mimeType = mimeType(for: fileURL)
        let lineBreak = "\r\n"
        var body = Data()

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\(lineBreak)"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(fileData)
        body.append(lineBreak.data(using: .utf8)!)
        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)

        return body
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a":
            return "audio/mp4"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        default:
            return "application/octet-stream"
        }
    }
}

struct DeviceRecordingDeleteResponse: Decodable, Equatable {
    let message: String
}

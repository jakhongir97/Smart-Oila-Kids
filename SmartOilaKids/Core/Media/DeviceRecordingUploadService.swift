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

    private let client: APIClient

    private func makeMultipartBody(fileURL: URL, boundary: String) throws -> Data {
        let fileData = try Data(contentsOf: fileURL)
        let lineBreak = "\r\n"
        var body = Data()

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\(lineBreak)"
                .data(using: .utf8)!
        )
        body.append("Content-Type: audio/mp4\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(fileData)
        body.append(lineBreak.data(using: .utf8)!)
        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)

        return body
    }
}

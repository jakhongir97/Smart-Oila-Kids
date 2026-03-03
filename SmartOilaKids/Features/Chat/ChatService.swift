import Foundation

protocol ChatServicing {
    func fetchChatHistory(dsn: String, limit: Int) async throws -> ChatMessagesModel
    func sendMessage(sendFromID: String, text: String, attachments: [Data]) async throws -> WBSocketChat
}

final class ChatService: ChatServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func fetchChatHistory(dsn: String, limit: Int = 100) async throws -> ChatMessagesModel {
        try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "messages/\(dsn)",
            method: .get,
            queryItems: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ],
            as: ChatMessagesModel.self
        )
    }

    func sendMessage(sendFromID: String, text: String, attachments: [Data] = []) async throws -> WBSocketChat {
        let boundary = UUID().uuidString
        let body = createMultipartBody(
            boundary: boundary,
            fields: [
                "send_from_id": sendFromID,
                "user_type": "child",
                "text": text
            ],
            attachments: attachments
        )

        return try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "messages/",
            method: .post,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            as: WBSocketChat.self
        )
    }

    private let client: APIClient
}

private extension ChatService {
    func createMultipartBody(boundary: String, fields: [String: String], attachments: [Data]) -> Data {
        var data = Data()

        for (key, value) in fields {
            data.append("--\(boundary)\r\n")
            data.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            data.append("\(value)\r\n")
        }

        for (index, value) in attachments.enumerated() {
            data.append("--\(boundary)\r\n")
            data.append("Content-Disposition: form-data; name=\"attachments\"; filename=\"image\(index + 1).jpg\"\r\n")
            data.append("Content-Type: image/jpeg\r\n\r\n")
            data.append(value)
            data.append("\r\n")
        }

        data.append("--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        guard let value = string.data(using: .utf8) else { return }
        append(value)
    }
}

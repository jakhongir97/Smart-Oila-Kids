import Foundation

protocol ChatServicing {
    func fetchChatHistory(dsn: String, limit: Int, page: Int) async throws -> ChatMessagesModel
    func sendMessage(sendFromID: String, text: String, attachments: [Data]) async throws -> WBSocketChat
    func fetchParentDisplayName() async throws -> String?
}

extension ChatServicing {
    func fetchParentDisplayName() async throws -> String? { nil }
}

final class ChatService: ChatServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func fetchChatHistory(dsn: String, limit: Int = 100, page: Int = 1) async throws -> ChatMessagesModel {
        try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "messages/\(dsn)",
            method: .get,
            queryItems: [
                URLQueryItem(name: "page", value: "\(max(1, page))"),
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

    func fetchParentDisplayName() async throws -> String? {
        do {
            let profile: MemberProfileNameResponse = try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "members/me",
                method: .get,
                headers: ["Accept": "application/json"],
                as: MemberProfileNameResponse.self
            )

            return profile.resolvedName?.trimmedNonEmpty
        } catch let NetworkError.server(statusCode, _) where statusCode == 401 || statusCode == 403 || statusCode == 404 {
            return nil
        }
    }

    private let client: APIClient
}

private struct MemberProfileNameResponse: Decodable {
    let name: String?
    let username: String?
    let fullName: String?
    let data: Nested?

    struct Nested: Decodable {
        let name: String?
        let username: String?
        let fullName: String?

        enum CodingKeys: String, CodingKey {
            case name
            case username
            case fullName = "full_name"
        }
    }

    var resolvedName: String? {
        name ?? username ?? fullName ?? data?.name ?? data?.username ?? data?.fullName
    }

    enum CodingKeys: String, CodingKey {
        case name
        case username
        case fullName = "full_name"
        case data
    }
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

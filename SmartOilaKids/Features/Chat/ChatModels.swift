import Foundation

struct ChatMessagesModel: Decodable {
    let pagination: Pagination
    var data: [String: [Datum]]

    enum CodingKeys: String, CodingKey {
        case pagination
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pagination = try container.decode(Pagination.self, forKey: .pagination)

        if let grouped = try? container.decode([String: [Datum]].self, forKey: .data) {
            data = grouped
            return
        }

        if let flat = try? container.decode([Datum].self, forKey: .data) {
            data = Dictionary(grouping: flat, by: \.dateKey)
            return
        }

        data = [:]
    }
}

struct Datum: Identifiable {
    var id: String { "\(time)-\(userType)-\((text ?? ""))" }

    let userType: String
    let text: String?
    let attachments: [String]
    let time: String

    var dateKey: String {
        Self.dateKey(from: time)
    }

    init(userType: String, text: String?, attachments: [String], time: String) {
        self.userType = userType
        self.text = text
        self.attachments = attachments
        self.time = time
    }

    enum CodingKeys: String, CodingKey {
        case userType = "user_type"
        case text
        case attachments
        case time
    }

    private static func dateKey(from input: String) -> String {
        if input.count >= 10 {
            return String(input.prefix(10))
        }
        return input
    }
}

extension Datum: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userType = (try? container.decode(String.self, forKey: .userType)) ?? "parent"
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        time = (try? container.decode(String.self, forKey: .time)) ?? ""
        attachments = decodeAttachmentList(from: container, key: .attachments)
    }
}

struct Pagination: Decodable {
    let current: Int
    let previous: Int?
    let next: Int?
    let perPage: Int
    let totalPage: Int
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case current, previous, next
        case perPage = "per_page"
        case totalPage = "total_page"
        case totalCount = "total_count"
    }
}

struct WBSocketMessage: Decodable {
    let event: String
    let data: ChatMessageWB
}

struct ChatMessageWB {
    let text: String?
    let attachments: [String]
    let time: String

    enum CodingKeys: String, CodingKey {
        case text
        case attachments
        case time
    }
}

extension ChatMessageWB: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        attachments = decodeAttachmentList(from: container, key: .attachments)
        time = (try? container.decode(String.self, forKey: .time)) ?? ""
    }
}

struct WBSocketChat: Decodable {
    let id: Int
    let createdAt: String
    let sendToID: String?
    let sendToType: String
    let sendFromID: String?
    let sendFromType: String
    let text: String?
    let attachments: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case sendToID = "send_to_id"
        case sendToType = "send_to_type"
        case sendFromID = "send_from_id"
        case sendFromType = "send_from_type"
        case text
        case attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        sendToID = try? container.decodeIfPresent(String.self, forKey: .sendToID)
        sendToType = (try? container.decode(String.self, forKey: .sendToType)) ?? "child"
        sendFromID = try? container.decodeIfPresent(String.self, forKey: .sendFromID)
        sendFromType = (try? container.decode(String.self, forKey: .sendFromType)) ?? "parent"
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        attachments = decodeAttachmentList(from: container, key: .attachments)
    }
}

private func decodeAttachmentList<K: CodingKey>(
    from container: KeyedDecodingContainer<K>,
    key: K
) -> [String] {
    if let items = try? container.decodeIfPresent([String].self, forKey: key) {
        return items
    }

    if let item = try? container.decodeIfPresent(String.self, forKey: key) {
        guard !item.isEmpty else { return [] }
        return [item]
    }

    return []
}

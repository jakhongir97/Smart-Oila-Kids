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
    var id: String { "\(time)-\(userType)-\((senderName ?? ""))-\((text ?? ""))-\(attachments.joined(separator: ","))" }

    let userType: String
    let text: String?
    let attachments: [String]
    let time: String
    let senderName: String?

    var dateKey: String {
        ChatTimestamp.dateKey(from: time)
    }

    init(userType: String, text: String?, attachments: [String], time: String, senderName: String? = nil) {
        self.userType = userType
        self.text = text
        self.attachments = attachments
        self.time = time
        self.senderName = senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CodingKeys: String, CodingKey {
        case userType = "user_type"
        case text
        case attachments
        case time
        case name
        case senderName = "sender_name"
        case fromName = "from_name"
        case parentName = "parent_name"
    }

}

extension Datum: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userType = container.decodeLossyStringIfPresent(forKey: .userType) ?? "parent"
        text = container.decodeLossyStringIfPresent(forKey: .text)
        time = container.decodeLossyStringIfPresent(forKey: .time) ?? ""
        attachments = decodeAttachmentList(from: container, key: .attachments)
        senderName = decodeFirstString(
            from: container,
            keys: [.name, .senderName, .fromName, .parentName]
        )
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = container.decodeLossyIntIfPresent(forKey: .current) ?? 0
        previous = container.decodeLossyIntIfPresent(forKey: .previous)
        next = container.decodeLossyIntIfPresent(forKey: .next)
        perPage = container.decodeLossyIntIfPresent(forKey: .perPage) ?? 0
        totalPage = container.decodeLossyIntIfPresent(forKey: .totalPage) ?? 0
        totalCount = container.decodeLossyIntIfPresent(forKey: .totalCount) ?? 0
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
    let senderName: String?

    enum CodingKeys: String, CodingKey {
        case text
        case attachments
        case time
        case name
        case senderName = "sender_name"
        case fromName = "from_name"
        case parentName = "parent_name"
    }
}

extension ChatMessageWB: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = container.decodeLossyStringIfPresent(forKey: .text)
        attachments = decodeAttachmentList(from: container, key: .attachments)
        time = container.decodeLossyStringIfPresent(forKey: .time) ?? ""
        senderName = decodeFirstString(
            from: container,
            keys: [.name, .senderName, .fromName, .parentName]
        )
    }
}

struct WBSocketChat: Decodable {
    let id: Int
    let createdAt: String
    let sendToID: String?
    let sendToType: String
    let sendFromID: String?
    let sendFromType: String
    let sendFromName: String?
    let text: String?
    let attachments: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case sendToID = "send_to_id"
        case sendToType = "send_to_type"
        case sendFromID = "send_from_id"
        case sendFromType = "send_from_type"
        case sendFromName = "send_from_name"
        case text
        case attachments
        case name
        case fromName = "from_name"
        case parentName = "parent_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyIntIfPresent(forKey: .id) ?? 0
        createdAt = container.decodeLossyStringIfPresent(forKey: .createdAt) ?? ""
        sendToID = container.decodeLossyStringIfPresent(forKey: .sendToID)
        sendToType = container.decodeLossyStringIfPresent(forKey: .sendToType) ?? "child"
        sendFromID = container.decodeLossyStringIfPresent(forKey: .sendFromID)
        sendFromType = container.decodeLossyStringIfPresent(forKey: .sendFromType) ?? "parent"
        sendFromName = decodeFirstString(
            from: container,
            keys: [.sendFromName, .name, .fromName, .parentName]
        )
        text = container.decodeLossyStringIfPresent(forKey: .text)
        attachments = decodeAttachmentList(from: container, key: .attachments)
    }
}

private func decodeAttachmentList<K: CodingKey>(
    from container: KeyedDecodingContainer<K>,
    key: K
) -> [String] {
    if let items = container.decodeLossyStringArrayIfPresent(forKey: key) {
        return items
    }

    return []
}

private func decodeFirstString<K: CodingKey>(
    from container: KeyedDecodingContainer<K>,
    keys: [K]
) -> String? {
    for key in keys {
        if let value = container.decodeLossyStringIfPresent(forKey: key),
           !value.isEmpty {
            return value
        }
    }
    return nil
}

import Foundation

struct APIFailureEnvelope: Decodable {
    let status: Bool?
    let message: String?
    let statusCode: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case message
        case statusCode = "status_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeLossyBoolIfPresent(forKey: .status)
        message = container.decodeLossyStringIfPresent(forKey: .message)
        statusCode = container.decodeLossyIntIfPresent(forKey: .statusCode)
    }
}

struct APITokenRefreshResponse: Decodable {
    let refreshToken: String?
    let accessToken: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case accessToken = "access_token"
        case tokenType = "token_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshToken = container.decodeLossyStringIfPresent(forKey: .refreshToken)
        accessToken = container.decodeLossyStringIfPresent(forKey: .accessToken)
        tokenType = container.decodeLossyStringIfPresent(forKey: .tokenType)
    }
}

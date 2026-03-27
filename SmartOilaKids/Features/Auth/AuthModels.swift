import Foundation

struct QRClaimRequest: Encodable {
    let token: String
    let deviceName: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case token
        case deviceName = "device_name"
        case appVersion = "app_version"
    }
}

struct AuthRegistrationResult {
    let dsn: String
    let deviceID: Int?
    let authorizationHeader: String?
    let refreshToken: String?

    init(
        dsn: String,
        deviceID: Int? = nil,
        authorizationHeader: String?,
        refreshToken: String?
    ) {
        self.dsn = dsn
        self.deviceID = deviceID
        self.authorizationHeader = authorizationHeader
        self.refreshToken = refreshToken
    }
}

struct AuthPhoneConfirmationContext: Equatable {
    let dsn: String
    let parentPhone: String
}

enum AuthPhoneSubmitResult: Equatable {
    case confirmationRequired(AuthPhoneConfirmationContext)
    case completed(AuthRegistrationResult)
}

extension AuthRegistrationResult: Equatable {}

struct AuthSessionTokens: Equatable {
    let authorizationHeader: String
    let refreshToken: String?
}

struct AuthScanPayload {
    let token: String?
    let refreshToken: String?
    let parentPhone: String?
    let dsn: String?
    let deviceName: String?

    var hasAuthData: Bool {
        token?.trimmedNonEmpty != nil
            || parentPhone?.trimmedNonEmpty != nil
            || (
                refreshToken?.trimmedNonEmpty != nil
                    && dsn?.trimmedNonEmpty != nil
            )
    }
}

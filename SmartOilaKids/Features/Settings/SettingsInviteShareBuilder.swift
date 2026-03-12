import Foundation

struct SettingsInviteSharePayload: Identifiable {
    let id = UUID()
    let message: String
}

enum SettingsInviteShareBuilder {
    static func payload(profileName: String, dsn: String?) -> SettingsInviteSharePayload {
        SettingsInviteSharePayload(message: message(profileName: profileName, dsn: dsn))
    }

    private static func message(profileName: String, dsn: String?) -> String {
        let resolvedName = profileName.trimmedNonEmpty ?? L10n.tr("settings.invite_share_default_name")
        let message = L10n.tr("settings.invite_share_message", resolvedName)
        let inviteURL = InviteLinkBuilder.makeURL(
            baseURL: AppConfig.inviteShareURL,
            inviterName: resolvedName,
            inviterDSN: dsn
        )
        return "\(message)\n\(inviteURL.absoluteString)"
    }
}

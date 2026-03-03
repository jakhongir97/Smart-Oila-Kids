import Foundation

enum SMSTemplatesStore {
    private static let key = "SMS_TEMPLATES"

    static func load(userDefaults: UserDefaults = .standard) -> [String] {
        if
            let data = userDefaults.data(forKey: key),
            let value = try? JSONDecoder().decode([String].self, from: data),
            !value.isEmpty
        {
            return value
        }

        return defaultTemplates()
    }

    static func save(_ templates: [String], userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        userDefaults.set(data, forKey: key)
    }

    private static func defaultTemplates() -> [String] {
        [
            L10n.tr("templates.default_1"),
            L10n.tr("templates.default_2"),
            L10n.tr("templates.default_3")
        ]
    }
}

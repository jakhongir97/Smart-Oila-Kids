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

    static func upsert(_ text: String, at index: Int?, in templates: [String]) -> [String] {
        guard let normalized = normalizedTemplate(text) else {
            return templates
        }

        var updated = templates
        if let index, updated.indices.contains(index) {
            updated[index] = normalized
        } else {
            updated.append(normalized)
        }
        return updated
    }

    static func delete(at index: Int, in templates: [String]) -> [String] {
        guard templates.indices.contains(index) else { return templates }
        var updated = templates
        updated.remove(at: index)
        return updated
    }

    static func normalizedTemplate(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
    }

    private static func defaultTemplates() -> [String] {
        [
            L10n.tr("templates.default_1"),
            L10n.tr("templates.default_2"),
            L10n.tr("templates.default_3")
        ]
    }
}

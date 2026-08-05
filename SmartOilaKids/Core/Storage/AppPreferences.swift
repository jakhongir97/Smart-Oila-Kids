import Foundation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case en
    case ru
    case uz
    case uzCyrl = "uz-Cyrl"

    var id: String { rawValue }

    var localeIdentifier: String { rawValue }

    /// Native display name for the language picker.
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .uz: return "O'zbekcha"
        case .uzCyrl: return "Ўзбекча"
        }
    }

    static var defaultForDevice: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? AppLanguage.en.rawValue
        if preferred.hasPrefix(AppLanguage.ru.rawValue) {
            return .ru
        }
        // The script subtag has to be tested BEFORE the bare "uz" prefix: "uz-Cyrl-UZ" also starts
        // with "uz", so a Cyrillic-Uzbek device would otherwise silently default to Latin.
        if preferred.hasPrefix(AppLanguage.uzCyrl.rawValue.lowercased()) {
            return .uzCyrl
        }
        if preferred.hasPrefix(AppLanguage.uz.rawValue) {
            return .uz
        }
        return .en
    }
}

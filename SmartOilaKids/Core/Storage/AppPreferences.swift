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

    var id: String { rawValue }

    var localeIdentifier: String { rawValue }

    static var defaultForDevice: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? AppLanguage.en.rawValue
        if preferred.hasPrefix(AppLanguage.ru.rawValue) {
            return .ru
        }
        if preferred.hasPrefix(AppLanguage.uz.rawValue) {
            return .uz
        }
        return .en
    }
}

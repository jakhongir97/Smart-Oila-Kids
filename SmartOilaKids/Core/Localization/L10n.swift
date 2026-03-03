import Foundation

enum L10n {
    private static let lock = NSLock()
    private static var languageBundle: Bundle = .main

    static func setLanguage(_ code: String) {
        let normalized = code.lowercased()
        let fallback = String(normalized.prefix(2))
        let bundle =
            Bundle.main.path(forResource: normalized, ofType: "lproj").flatMap(Bundle.init(path:))
            ?? Bundle.main.path(forResource: fallback, ofType: "lproj").flatMap(Bundle.init(path:))
            ?? .main

        lock.lock()
        languageBundle = bundle
        lock.unlock()
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        lock.lock()
        let bundle = languageBundle
        lock.unlock()

        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        guard !args.isEmpty else {
            return format
        }
        return String(format: format, locale: Locale.current, arguments: args)
    }
}

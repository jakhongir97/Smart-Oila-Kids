import Foundation

enum L10n {
    private static let lock = NSLock()
    private static var languageBundle: Bundle = .main
    private static var cyrillic = false

    static func setLanguage(_ code: String) {
        let normalized = code.lowercased()
        // Uzbek Cyrillic reuses the Uzbek Latin strings, transliterated at read time —
        // so every string is covered without a separate uz-Cyrl.lproj.
        let isCyrillic = (normalized == "uz-cyrl")
        let resource = isCyrillic ? "uz" : normalized
        let fallback = String(resource.prefix(2))
        let bundle =
            Bundle.main.path(forResource: resource, ofType: "lproj").flatMap(Bundle.init(path:))
            ?? Bundle.main.path(forResource: fallback, ofType: "lproj").flatMap(Bundle.init(path:))
            ?? .main

        lock.lock()
        languageBundle = bundle
        cyrillic = isCyrillic
        lock.unlock()
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        lock.lock()
        let bundle = languageBundle
        let toCyrillic = cyrillic
        lock.unlock()

        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        let result = args.isEmpty
            ? format
            : String(format: format, locale: Locale.current, arguments: args)
        return toCyrillic ? UzbekCyrillic.transliterate(result) : result
    }
}

/// Deterministic Uzbek Latin → Cyrillic transliteration. Digraphs and apostrophe
/// combinations are handled before single letters (order matters). Digits, punctuation,
/// and format placeholders pass through untouched.
enum UzbekCyrillic {
    private static let cacheLock = NSLock()
    private static var cache: [String: String] = [:]
    private static let cacheLimit = 2000

    static func transliterate(_ input: String) -> String {
        // Transliteration is a pure function of the input but costs ~90 full-string passes, and
        // L10n.tr calls it on every localized string while in Cyrillic mode. Memoize the result
        // (the UI reuses a bounded set of labels) so repeat renders are a dictionary lookup.
        cacheLock.lock()
        if let cached = cache[input] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var s = input
        for (from, to) in map {
            s = s.replacingOccurrences(of: from, with: to)
        }

        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[input] = s
        cacheLock.unlock()
        return s
    }

    private static let map: [(String, String)] = [
        // o' / g' variants (straight quote, curly quotes, backtick)
        ("O'", "Ў"), ("O\u{2018}", "Ў"), ("O\u{2019}", "Ў"), ("Oʻ", "Ў"),
        ("o'", "ў"), ("o\u{2018}", "ў"), ("o\u{2019}", "ў"), ("oʻ", "ў"),
        ("G'", "Ғ"), ("G\u{2018}", "Ғ"), ("G\u{2019}", "Ғ"), ("Gʻ", "Ғ"),
        ("g'", "ғ"), ("g\u{2018}", "ғ"), ("g\u{2019}", "ғ"), ("gʻ", "ғ"),
        // digraphs
        ("Sh", "Ш"), ("SH", "Ш"), ("sh", "ш"),
        ("Ch", "Ч"), ("CH", "Ч"), ("ch", "ч"),
        ("Yo", "Ё"), ("YO", "Ё"), ("yo", "ё"),
        ("Yu", "Ю"), ("YU", "Ю"), ("yu", "ю"),
        ("Ya", "Я"), ("YA", "Я"), ("ya", "я"),
        ("Ye", "Е"), ("YE", "Е"), ("ye", "е"),
        ("Ts", "Ц"), ("ts", "ц"),
        // single letters
        ("A", "А"), ("a", "а"), ("B", "Б"), ("b", "б"), ("D", "Д"), ("d", "д"),
        ("E", "Е"), ("e", "е"), ("F", "Ф"), ("f", "ф"), ("G", "Г"), ("g", "г"),
        ("H", "Ҳ"), ("h", "ҳ"), ("I", "И"), ("i", "и"), ("J", "Ж"), ("j", "ж"),
        ("K", "К"), ("k", "к"), ("L", "Л"), ("l", "л"), ("M", "М"), ("m", "м"),
        ("N", "Н"), ("n", "н"), ("O", "О"), ("o", "о"), ("P", "П"), ("p", "п"),
        ("Q", "Қ"), ("q", "қ"), ("R", "Р"), ("r", "р"), ("S", "С"), ("s", "с"),
        ("T", "Т"), ("t", "т"), ("U", "У"), ("u", "у"), ("V", "В"), ("v", "в"),
        ("X", "Х"), ("x", "х"), ("Y", "Й"), ("y", "й"), ("Z", "З"), ("z", "з"),
        ("C", "С"), ("c", "с"),
        // tutuq belgisi (glottal stop) — any remaining apostrophe
        ("'", "ъ"), ("\u{2019}", "ъ"), ("\u{2018}", "ъ")
    ]
}

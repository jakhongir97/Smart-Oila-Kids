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
        // Transliterate the FORMAT string first, then substitute args — so runtime values (an app
        // name via %@, a number via %d) are inserted after transliteration and not mangled into
        // Cyrillic gibberish. transliterate() protects the format specifiers themselves.
        let localizedFormat = toCyrillic ? UzbekCyrillic.transliterate(format) : format
        return args.isEmpty
            ? localizedFormat
            : String(format: localizedFormat, locale: Locale.current, arguments: args)
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

        // Protect printf-style format specifiers (%d, %@, %1$@, %%, …) so their conversion letter
        // isn't transliterated (e.g. %d → %д), which would break a String(format:) applied later
        // and silently drop the value.
        let (protectedInput, specifiers) = protectFormatSpecifiers(input)

        var s = protectedInput
        // Word-initial "e" is "э" in Uzbek Cyrillic (elsewhere "е"). Apply before the general map.
        s = replaceWordInitialE(s)
        for (from, to) in map {
            s = s.replacingOccurrences(of: from, with: to)
        }
        for (index, specifier) in specifiers.enumerated() {
            s = s.replacingOccurrences(of: token(index), with: specifier)
        }

        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[input] = s
        cacheLock.unlock()
        return s
    }

    /// Private-use sentinel wrapping a run index. Both the PUA scalars and the digits pass through
    /// the transliteration map untouched, so the token survives to be restored afterwards.
    private static func token(_ index: Int) -> String { "\u{E000}\(index)\u{E001}" }

    private static let formatSpecifierRegex = try? NSRegularExpression(
        pattern: "%(?:\\d+\\$)?[-+ 0#]?\\d*(?:\\.\\d+)?[@%a-zA-Z]"
    )

    private static func protectFormatSpecifiers(_ input: String) -> (String, [String]) {
        guard let regex = formatSpecifierRegex else { return (input, []) }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (input, []) }

        var result = ""
        var specifiers: [String] = []
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += token(specifiers.count)
            specifiers.append(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return (result, specifiers)
    }

    private static let wordInitialERegex = try? NSRegularExpression(
        pattern: "(?<![\\p{L}])([eE])"
    )

    private static func replaceWordInitialE(_ input: String) -> String {
        guard let regex = wordInitialERegex else { return input }
        let ns = input as NSString
        var result = input
        // Replace back-to-front so ranges stay valid.
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)).reversed() {
            let letter = ns.substring(with: match.range)
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: letter == "E" ? "Э" : "э")
        }
        return result
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

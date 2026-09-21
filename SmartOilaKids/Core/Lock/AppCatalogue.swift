import Foundation

/// One app this build knows how to NAME, DETECT and BLOCK on a child's iPhone.
///
/// The three abilities are independent and the catalogue is where that asymmetry lives:
///
/// * `bundleId` is the IDENTITY the server and this app agree on. It does NOT block by itself:
///   `blockedApplications` built from `Application(bundleIdentifier:)` was measured inert on iOS
///   26.6.1 (see `BlockedApplicationsController`), so a bundle id is resolved to an
///   `ApplicationToken` via `ApplicationTokenCatalogue` before anything is enforced.
/// * `scheme` drives DETECTION — `UIApplication.canOpenURL("<scheme>://")`. It is nil for most
///   entries, because iOS has no API that lists installed apps outside the EU and a scheme is the
///   only silent probe. **An app with no scheme can still be blocked, it just cannot be listed.**
/// * `name` is what the parent reads. iOS cannot read an installed app's display name either
///   (`Application.bundleIdentifier`/`localizedDisplayName` are nil outside a shield-configuration
///   extension), so the name has to be shipped with the app, not discovered on the device.
///
/// Every `bundleId` here was verified against `itunes.apple.com/lookup?bundleId=…&country=uz` on
/// 2026-09-13. Do not add an entry from memory — a wrong bundle id blocks nothing and fails
/// silently, which is indistinguishable from "the child does not have that app".
struct AppCatalogueEntry: Equatable, Hashable {
    let name: String
    let bundleId: String
    /// URL scheme for `canOpenURL`, or nil when the app can only be blocked, never detected.
    /// Every non-nil value MUST also be listed in `LSApplicationQueriesSchemes` in Info.plist:
    /// an undeclared scheme returns `false` even when the app IS installed.
    let scheme: String?
    let category: String
}

enum AppCatalogue {
    /// Ordered by how often a Bolajon360 parent actually asks about the app. The order decides
    /// which apps are PROBED first and therefore the order of the list the parent sees; it does
    /// not decide which blocks survive Apple's 50-app cap — that is the server's order, kept by
    /// `BlockedApplicationsController.resolveBlockedBundleIds`.
    static let all: [AppCatalogueEntry] = [
        // Messaging, social and video — the apps parents name unprompted.
        AppCatalogueEntry(name: "Telegram", bundleId: "ph.telegra.Telegraph", scheme: "tg", category: "messaging"),
        AppCatalogueEntry(name: "TikTok", bundleId: "com.zhiliaoapp.musically", scheme: "snssdk1233", category: "social"),
        AppCatalogueEntry(name: "Instagram", bundleId: "com.burbn.instagram", scheme: "instagram", category: "social"),
        AppCatalogueEntry(name: "YouTube", bundleId: "com.google.ios.youtube", scheme: "youtube", category: "video"),
        AppCatalogueEntry(name: "WhatsApp", bundleId: "net.whatsapp.WhatsApp", scheme: "whatsapp", category: "messaging"),
        AppCatalogueEntry(name: "Snapchat", bundleId: "com.toyopagroup.picaboo", scheme: "snapchat", category: "social"),
        AppCatalogueEntry(name: "Discord", bundleId: "com.hammerandchisel.discord", scheme: "discord", category: "messaging"),
        AppCatalogueEntry(name: "Facebook", bundleId: "com.facebook.Facebook", scheme: "fb", category: "social"),
        AppCatalogueEntry(name: "Messenger", bundleId: "com.facebook.Messenger", scheme: "fb-messenger", category: "messaging"),
        AppCatalogueEntry(name: "X", bundleId: "com.atebits.Tweetie2", scheme: "twitter", category: "social"),
        AppCatalogueEntry(name: "Reddit", bundleId: "com.reddit.Reddit", scheme: "reddit", category: "social"),
        // Games.
        AppCatalogueEntry(name: "Roblox", bundleId: "com.roblox.robloxmobile", scheme: "roblox", category: "games"),
        AppCatalogueEntry(name: "PUBG Mobile", bundleId: "com.tencent.ig", scheme: "fb1036341366506456", category: "games"),
        AppCatalogueEntry(name: "Standoff 2", bundleId: "com.axlebolt.standoff2", scheme: "fb752573801798020", category: "games"),
        AppCatalogueEntry(name: "Free Fire", bundleId: "com.dts.freefireth", scheme: "fb2036793259884297", category: "games"),
        AppCatalogueEntry(name: "Brawl Stars", bundleId: "com.supercell.laser", scheme: "brawlstars", category: "games"),
        AppCatalogueEntry(name: "Minecraft", bundleId: "com.mojang.minecraftpe", scheme: "minecraft", category: "games"),
        AppCatalogueEntry(name: "Clash Royale", bundleId: "com.supercell.scroll", scheme: "clashroyale", category: "games"),
        AppCatalogueEntry(name: "Clash of Clans", bundleId: "com.supercell.magic", scheme: "clashofclans", category: "games"),
        AppCatalogueEntry(name: "Mobile Legends", bundleId: "com.mobile.legends", scheme: "mobilelegends", category: "games"),
        AppCatalogueEntry(name: "Fortnite", bundleId: "com.epicgames.FortniteGame", scheme: "com.epicgames.fortnite", category: "games"),
        // Browsers and AI — the routes around every other block.
        AppCatalogueEntry(name: "Google Chrome", bundleId: "com.google.chrome.ios", scheme: "googlechrome", category: "browser"),
        AppCatalogueEntry(name: "Yandex Browser", bundleId: "ru.yandex.mobile.search", scheme: "yandexbrowser-open-url", category: "browser"),
        AppCatalogueEntry(name: "ChatGPT", bundleId: "com.openai.chat", scheme: "chatgpt", category: "ai"),
        AppCatalogueEntry(name: "Spotify", bundleId: "com.spotify.client", scheme: "spotify", category: "music"),
        // Popular in Uzbekistan — schemes verified 2026-09-21 (Yandex launch docs, curated scheme lists).
        AppCatalogueEntry(name: "Yandex Maps", bundleId: "ru.yandex.traffic", scheme: "yandexmaps", category: "navigation"),
        AppCatalogueEntry(name: "Yandex Go", bundleId: "ru.yandex.ytaxi", scheme: "yandextaxi", category: "navigation"),
        AppCatalogueEntry(name: "Yandex Navi", bundleId: "ru.yandex.mobile.navigator", scheme: "yandexnavi", category: "navigation"),
        AppCatalogueEntry(name: "AliExpress", bundleId: "com.alibaba.iAliexpress", scheme: "aliexpress", category: "shopping"),
        AppCatalogueEntry(name: "VK", bundleId: "com.vk.vkclient", scheme: "vk", category: "social"),
        AppCatalogueEntry(name: "Signal", bundleId: "org.whispersystems.signal", scheme: "sgnl", category: "messaging"),
        AppCatalogueEntry(name: "Gmail", bundleId: "com.google.Gmail", scheme: "googlegmail", category: "messaging"),

        // ── Everything below can be BLOCKED but not DETECTED (no verified scheme). ──
        AppCatalogueEntry(name: "Likee", bundleId: "video.like", scheme: nil, category: "social"),
        AppCatalogueEntry(name: "CapCut", bundleId: "com.lemon.lvoverseas", scheme: nil, category: "creative"),
        AppCatalogueEntry(name: "Threads", bundleId: "com.burbn.barcelona", scheme: nil, category: "social"),
        AppCatalogueEntry(name: "Pinterest", bundleId: "pinterest", scheme: nil, category: "social"),
        AppCatalogueEntry(name: "Twitch", bundleId: "tv.twitch", scheme: "twitch", category: "video"),
        AppCatalogueEntry(name: "Netflix", bundleId: "com.netflix.Netflix", scheme: "nflx", category: "video"),
        AppCatalogueEntry(name: "YouTube Kids", bundleId: "com.google.ios.youtubekids", scheme: nil, category: "video"),
        AppCatalogueEntry(name: "Kinopoisk", bundleId: "ru.kinopoisk", scheme: nil, category: "video"),
        AppCatalogueEntry(name: "Genshin Impact", bundleId: "com.miHoYo.GenshinImpact", scheme: nil, category: "games"),
        AppCatalogueEntry(name: "Free Fire MAX", bundleId: "com.dts.freefiremax", scheme: nil, category: "games"),
        AppCatalogueEntry(name: "Call of Duty Mobile", bundleId: "com.activision.callofduty.shooter", scheme: nil, category: "games"),
        AppCatalogueEntry(name: "Among Us", bundleId: "com.innersloth.amongus", scheme: nil, category: "games"),
        AppCatalogueEntry(name: "Subway Surfers", bundleId: "com.kiloo.subwaysurfers", scheme: nil, category: "games"),
        AppCatalogueEntry(name: "Stumble Guys", bundleId: "com.kitkagames.fallbuddies", scheme: nil, category: "games"),
        AppCatalogueEntry(name: "8 Ball Pool", bundleId: "com.miniclip.8ballpoolmult", scheme: nil, category: "games"),
        AppCatalogueEntry(name: "Character.AI", bundleId: "ai.character.app", scheme: nil, category: "ai"),
        AppCatalogueEntry(name: "imo", bundleId: "imoimiphone", scheme: nil, category: "messaging"),
        AppCatalogueEntry(name: "Viber", bundleId: "com.viber", scheme: nil, category: "messaging"),
        AppCatalogueEntry(name: "Yandex Music", bundleId: "ru.yandex.mobile.music", scheme: "yandexmusic", category: "music"),
        AppCatalogueEntry(name: "Shazam", bundleId: "com.shazam.Shazam", scheme: nil, category: "music"),
        AppCatalogueEntry(name: "Opera", bundleId: "com.opera.OperaTouch", scheme: nil, category: "browser"),
        // Safari is an Apple app, so it has no App Store listing and no scheme of ours to probe —
        // but Apple's own documentation and forum guidance say it blocks by bundle id like any
        // other. The Phone app does not, which is why it is in `neverBlockBundleIds` instead.
        AppCatalogueEntry(name: "Safari", bundleId: "com.apple.mobilesafari", scheme: nil, category: "browser"),
        AppCatalogueEntry(name: "Duolingo", bundleId: "com.duolingo.DuolingoMobile", scheme: nil, category: "education"),
        AppCatalogueEntry(name: "Wildberries", bundleId: "RU.WILDBERRIES.MOBILEAPP", scheme: nil, category: "shopping"),
        AppCatalogueEntry(name: "Ozon", bundleId: "ru.ozon.OzonStore", scheme: nil, category: "shopping"),

        // ── Uzbek apps (App Store bundle ids verified 2026-09-21; no public URL scheme, so
        //    blockable and linkable-by-tap, but not auto-detected). ──
        AppCatalogueEntry(name: "Payme", bundleId: "uz.payme.Payme", scheme: nil, category: "finance"),
        AppCatalogueEntry(name: "Click", bundleId: "com.ssdsoftwaresolutions.clickuz", scheme: nil, category: "finance"),
        AppCatalogueEntry(name: "Uzum Market", bundleId: "uz.uzum.app", scheme: nil, category: "shopping"),
        AppCatalogueEntry(name: "Uzum Bank", bundleId: "uz.kapitalbank.apelsin", scheme: nil, category: "finance"),
        AppCatalogueEntry(name: "Uzum Tezkor", bundleId: "uz.uzum.tezkor", scheme: nil, category: "shopping"),
        AppCatalogueEntry(name: "Paynet", bundleId: "GS.Uzpaynet", scheme: nil, category: "finance"),
        AppCatalogueEntry(name: "Alif", bundleId: "tj.alif.mobi", scheme: nil, category: "finance"),
        AppCatalogueEntry(name: "Anor Bank", bundleId: "uz.anorbank.mobile", scheme: nil, category: "finance"),
        AppCatalogueEntry(name: "TBC UZ", bundleId: "ge.tbc.tbcuz", scheme: nil, category: "finance"),
        AppCatalogueEntry(name: "Humans", bundleId: "net.humans.fintech-uz", scheme: nil, category: "finance"),
        AppCatalogueEntry(name: "My Beeline", bundleId: "uz.beeline.odp", scheme: nil, category: "utility"),
        AppCatalogueEntry(name: "Ucell", bundleId: "uz.ucell.ucellmobile", scheme: nil, category: "utility"),
        AppCatalogueEntry(name: "Mobiuz", bundleId: "uz.mobiuz.mobiservice", scheme: nil, category: "utility"),
        AppCatalogueEntry(name: "Uzmobile", bundleId: "com.cr204.Uztelecom", scheme: nil, category: "utility"),
        AppCatalogueEntry(name: "MyGov", bundleId: "uz.uzinfocom.mygov", scheme: nil, category: "utility"),
        AppCatalogueEntry(name: "Express24", bundleId: "com.uznewmax.theflash", scheme: nil, category: "shopping"),
        AppCatalogueEntry(name: "Wolt", bundleId: "com.woltapp.wolt", scheme: nil, category: "shopping"),
        AppCatalogueEntry(name: "Zoodmall", bundleId: "com.orientswiss.b2c.kazakhstan", scheme: nil, category: "shopping"),
        AppCatalogueEntry(name: "VK Video", bundleId: "com.vk.vkvideo", scheme: nil, category: "video"),
    ]

    /// The schemes to probe. MUST equal `LSApplicationQueriesSchemes` in Info.plist exactly —
    /// pinned by `AppCatalogueTests.testEveryProbeSchemeIsDeclaredInTheInfoPlist`.
    static var probeSchemes: [String] { all.compactMap(\.scheme) }

    /// Apple's documented ceiling on `LSApplicationQueriesSchemes`: 50 for a binary linked with the
    /// iOS 15+ SDK, **25 once linked with the iOS 27 SDK**. Overflow behaviour is undocumented and
    /// silent, so the catalogue is built against the lower number and never has to be cut later.
    static let maximumProbeSchemes = 50

    /// Apple's documented ceiling on `ApplicationSettings.blockedApplications`:
    /// "Your app can shield up to 50 applications at once." Past it, developers report that
    /// *nothing* is blocked rather than the first 50 — the worst possible failure for this product,
    /// which is why the cap is enforced on our side.
    static let maximumBlockedApplications = 50

    static func entry(forBundleId bundleId: String) -> AppCatalogueEntry? {
        let normalized = normalizedBundleId(bundleId)
        return all.first { normalizedBundleId($0.bundleId) == normalized }
    }

    /// The catalogue's canonical spelling of a bundle id, or the input unchanged when unknown.
    ///
    /// Load-bearing: the usage-report extension lower-cases every bundle id it reports, so the
    /// server's `lockedPackages` come back lower-cased too (`ru.wildberries.mobileapp`), while
    /// `Application(bundleIdentifier:)` is matched by the system against the real, case-sensitive
    /// id (`RU.WILDBERRIES.MOBILEAPP`). Without this round-trip those apps would silently never
    /// block.
    static func canonicalBundleId(_ bundleId: String) -> String {
        entry(forBundleId: bundleId)?.bundleId ?? bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to show a parent for a bundle id we know; nil for one we do not, so the caller can
    /// decide between hiding the row and showing the raw id.
    static func displayName(forBundleId bundleId: String) -> String? {
        entry(forBundleId: bundleId)?.name
    }

    static func normalizedBundleId(_ bundleId: String) -> String {
        bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Turns "which of the apps we know about are on this phone?" into a pure function of a
/// `canOpenURL` probe, so the rule is testable without a device, a simulator or UIKit.
enum InstalledAppProbe {
    /// Entries whose scheme answers `true`, in catalogue order.
    ///
    /// `canOpen` receives the bare scheme (`"tg"`), not a URL, because the URL shape is the
    /// caller's business and a malformed one would silently read as "not installed".
    nonisolated static func installedEntries(
        in catalogue: [AppCatalogueEntry] = AppCatalogue.all,
        canOpen: (String) -> Bool
    ) -> [AppCatalogueEntry] {
        catalogue.filter { entry in
            guard let scheme = entry.scheme, !scheme.isEmpty else { return false }
            return canOpen(scheme)
        }
    }

    /// The `PUT /device/apps/sync` payload for a probe result.
    ///
    /// `SyncAppsDto` declares `minItems: 1`, so an empty result must not be sent at all — the
    /// caller gets an empty array and is expected to skip the request rather than 400 the device's
    /// own liveness path.
    nonisolated static func syncEntries(for installed: [AppCatalogueEntry]) -> [DeviceAppLockSyncEntry] {
        // Lower-cased on purpose. The usage-report extension lower-cases every bundle id it sends
        // to `POST /device/apps/usage`, so sending the catalogue's canonical casing here would
        // publish the SAME app under two primary keys — `RU.WILDBERRIES.MOBILEAPP` in the app list
        // and `ru.wildberries.mobileapp` in the usage rows — and the parent panel could never join
        // them. The real casing is restored on the way back in, where iOS needs it, by
        // `AppCatalogue.canonicalBundleId`.
        installed.map {
            DeviceAppLockSyncEntry(packageName: AppCatalogue.normalizedBundleId($0.bundleId), name: $0.name)
        }
    }
}

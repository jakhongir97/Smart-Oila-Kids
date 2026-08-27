import Foundation
import UserNotifications
import SwiftUI

final class SessionStore: ObservableObject {
    static let profileNameDefaultsKey = "PROFILE_NAME"

    private enum Keys {
        static let dsn = "DSN"
        static let profileName = SessionStore.profileNameDefaultsKey
        static let childAvatarEmoji = "CHILD_AVATAR_EMOJI"
        static let childProfileColor = "CHILD_PROFILE_COLOR"
        static let appTheme = "APP_THEME"
        static let appLanguage = "APP_LANGUAGE"
        static let setupCompleted = "BOLAJON_SETUP_COMPLETED"
        static let onboardingCompleted = "BOLAJON_ONBOARDING_COMPLETED"
        static let oilaPaired = "BOLAJON_OILA_PAIRED"
        static let pairedAt = "BOLAJON_PAIRED_AT"
        static let routingMigrated = "BOLAJON_ROUTING_MIGRATED"
        static let migratedFromLegacy = "BOLAJON_MIGRATED_FROM_LEGACY"
    }

    @Published private(set) var dsn: String?
    @Published var profileName: String
    /// Emoji avatar the parent chose for this child (from `POST /device/pair` → child.avatarEmoji).
    @Published private(set) var childAvatarEmoji: String?
    /// Hex profile color the parent chose for this child (child.profileColor, e.g. "#F0605A").
    @Published private(set) var childProfileColor: String?
    @Published private(set) var apiAccessToken: String?
    @Published private(set) var apiRefreshToken: String?
    @Published private(set) var appTheme: AppTheme
    @Published private(set) var appLanguage: AppLanguage
    /// Bolajon360 redesign routing: setup flow (A1–A4) finished.
    @Published private(set) var setupCompleted: Bool = false
    /// Bolajon360 redesign routing: permissions onboarding (B1–B11) finished.
    @Published private(set) var onboardingCompleted: Bool = false
    /// True only after a successful oila360 `POST /device/pair` issued this install's tokens.
    /// Gates telemetry — a legacy DSN alone is NOT an oila360 credential.
    @Published private(set) var oilaPaired: Bool = false
    /// True when the one-time routing migration reset an EXISTING install (legacy DSN or
    /// previously-completed flow) — as opposed to a fresh install, which also runs the
    /// migration branch but has nothing to lose. Drives the "re-link to keep protection on"
    /// notice in the setup flow.
    @Published private(set) var migratedFromLegacy: Bool = false

    init(
        userDefaults: UserDefaults = .standard,
        secureTokens: SecureTokenStoring = SecureTokenStore.shared,
        deviceTokens: SecureTokenStoring = SecureTokenStore.oila,
        // The NAME, not the `UserDefaults`, because the disconnect purge removes the whole
        // persistent domain and `removePersistentDomain(forName:)` acts on the named domain rather
        // than on the receiver — hand it the shared identifier and it wipes the real container no
        // matter which instance it was called on. Injected at all because that container is real,
        // shared and device-global: a test that let the default through would delete the
        // schedule-monitor extension's storage out from under any other test using it.
        appGroupIdentifier: String = ScreenTimeUsageAppGroup.identifier
    ) {
        self.userDefaults = userDefaults
        self.secureTokens = secureTokens
        self.deviceTokens = deviceTokens
        self.appGroupIdentifier = appGroupIdentifier
        self.appGroupDefaults = UserDefaults(suiteName: appGroupIdentifier)

        secureTokens.migrateFromUserDefaults(userDefaults)

        let resolvedLanguage = SessionStore.defaultLanguage(userDefaults: userDefaults)
        L10n.setLanguage(resolvedLanguage.rawValue)
        // Mirror on every launch, not only in setLanguage: a child who never opens the language
        // picker still has a resolved language, and without this the schedule-monitor extension
        // finds no APP_LANGUAGE in the App Group and falls back to the DEVICE language for its
        // system notifications — the exact mismatch the localization fix was meant to remove.
        appGroupDefaults?.set(resolvedLanguage.rawValue, forKey: Keys.appLanguage)

        dsn = userDefaults.string(forKey: Keys.dsn)?.trimmedNonEmpty
        profileName = userDefaults.string(forKey: Keys.profileName) ?? L10n.tr("common.user_default")
        childAvatarEmoji = userDefaults.string(forKey: Keys.childAvatarEmoji)?.trimmedNonEmpty
        childProfileColor = userDefaults.string(forKey: Keys.childProfileColor)?.trimmedNonEmpty
        apiAccessToken = secureTokens.accessToken()
        apiRefreshToken = secureTokens.refreshToken()
        appTheme = AppTheme(rawValue: userDefaults.string(forKey: Keys.appTheme) ?? "") ?? .system
        appLanguage = resolvedLanguage

        // Bolajon360 routing migration (one-time). The oila360 backend replaced the legacy one,
        // so a legacy DSN carries NO oila360 credentials AND no guarantee the new flow's
        // permissions (Always-location, Screen Time authorization) were ever granted. Send every
        // migrated user through the full setup + B1–B11 permission flow once (all flags false):
        // skipping onboarding for "already linked" users is what left telemetry silently
        // un-permissioned. Marking them "paired" without tokens would 401-loop telemetry forever.
        if !userDefaults.bool(forKey: Keys.routingMigrated) {
            // Capture BEFORE resetting: a fresh install also passes through this branch, but
            // only an upgrading install has a legacy DSN or previously-completed flow state.
            let hadExistingInstallState = dsn != nil
                || userDefaults.bool(forKey: Keys.setupCompleted)
                || userDefaults.bool(forKey: Keys.onboardingCompleted)
                || userDefaults.bool(forKey: Keys.oilaPaired)
            userDefaults.set(false, forKey: Keys.setupCompleted)
            userDefaults.set(false, forKey: Keys.onboardingCompleted)
            userDefaults.set(false, forKey: Keys.oilaPaired)
            userDefaults.set(true, forKey: Keys.routingMigrated)
            if hadExistingInstallState {
                userDefaults.set(true, forKey: Keys.migratedFromLegacy)
            }
        }
        setupCompleted = userDefaults.bool(forKey: Keys.setupCompleted)
        onboardingCompleted = userDefaults.bool(forKey: Keys.onboardingCompleted)
        oilaPaired = userDefaults.bool(forKey: Keys.oilaPaired)
        migratedFromLegacy = userDefaults.bool(forKey: Keys.migratedFromLegacy)

#if DEBUG
        SessionStore.debugThemeLog(
            "init theme=\(appTheme.rawValue) storedRaw=\(userDefaults.string(forKey: Keys.appTheme) ?? "nil") language=\(appLanguage.rawValue)"
        )
#endif
    }

    func setDSN(_ value: String?) {
        let normalized = value?.trimmedNonEmpty
        dsn = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: Keys.dsn)
        } else {
            userDefaults.removeObject(forKey: Keys.dsn)
        }
    }

    func setProfileName(_ name: String) {
        profileName = name
        userDefaults.set(name, forKey: Keys.profileName)
    }

    func setChildAvatarEmoji(_ emoji: String?) {
        let normalized = emoji?.trimmedNonEmpty
        childAvatarEmoji = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: Keys.childAvatarEmoji)
        } else {
            userDefaults.removeObject(forKey: Keys.childAvatarEmoji)
        }
    }

    func setChildProfileColor(_ hex: String?) {
        let normalized = hex?.trimmedNonEmpty
        childProfileColor = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: Keys.childProfileColor)
        } else {
            userDefaults.removeObject(forKey: Keys.childProfileColor)
        }
    }

    func setAPIAccessToken(_ token: String?) {
        secureTokens.setAccessToken(normalizeAccessToken(token))
        apiAccessToken = secureTokens.accessToken()
    }

    func setAPIRefreshToken(_ token: String?) {
        secureTokens.setRefreshToken(token)
        apiRefreshToken = secureTokens.refreshToken()
    }

    func setTheme(_ value: AppTheme) {
#if DEBUG
        let previousTheme = appTheme.rawValue
        let previousStoredValue = userDefaults.string(forKey: Keys.appTheme) ?? "nil"
        SessionStore.debugThemeLog(
            "setTheme requested=\(value.rawValue) previousTheme=\(previousTheme) previousStoredRaw=\(previousStoredValue)"
        )
#endif
        appTheme = value
        userDefaults.set(value.rawValue, forKey: Keys.appTheme)
#if DEBUG
        SessionStore.debugThemeLog(
            "setTheme applied theme=\(appTheme.rawValue) storedRaw=\(userDefaults.string(forKey: Keys.appTheme) ?? "nil")"
        )
#endif
    }

    func setLanguage(_ value: AppLanguage) {
        appLanguage = value
        userDefaults.set(value.rawValue, forKey: Keys.appLanguage)
        // Mirror into the App Group so the schedule-monitor extension localizes its system
        // notifications in the family's chosen language rather than the device language.
        appGroupDefaults?.set(value.rawValue, forKey: Keys.appLanguage)
        L10n.setLanguage(value.rawValue)
    }

    func setSetupCompleted(_ value: Bool) {
        setupCompleted = value
        userDefaults.set(value, forKey: Keys.setupCompleted)
    }

    func setOnboardingCompleted(_ value: Bool) {
        onboardingCompleted = value
        userDefaults.set(value, forKey: Keys.onboardingCompleted)
    }

    /// When this install last completed `POST /device/pair`, or nil if it never has.
    ///
    /// It used to be a PARENT-PRESENCE signal: first-PIN provisioning was legal for 15 minutes after
    /// it. That is gone, and deliberately — the child owns the Date & Time pane, so the comparison
    /// was reading an attacker-controlled clock, and the stamp lands at code redemption, BEFORE the
    /// B1–B11 permissions flow, so the window was routinely spent before Home ever opened. See
    /// `FirstPINProvisioning`, which now uses a one-shot grant and reads no clock at all. The stamp
    /// itself stays because it records when this device joined a family, which nothing else does.
    var pairedAt: Date? {
        let stamp = userDefaults.double(forKey: Keys.pairedAt)
        guard stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    func setOilaPaired(_ value: Bool) {
        oilaPaired = value
        userDefaults.set(value, forKey: Keys.oilaPaired)
        if value {
            userDefaults.set(Date().timeIntervalSince1970, forKey: Keys.pairedAt)
        } else {
            userDefaults.removeObject(forKey: Keys.pairedAt)
        }
        if value {
            // The migration re-link notice is a one-time upgrade prompt. Once this install pairs,
            // clear the flag so a later voluntary disconnect doesn't resurrect the notice for a
            // user who is no longer a freshly-migrated install.
            migratedFromLegacy = false
            userDefaults.set(false, forKey: Keys.migratedFromLegacy)

            // Wipe any parent-PIN verifier left over from a PREVIOUS pairing of this device.
            //
            // The unpair path already clears it (purgeChildScopedData → wipePersistedPINState), but
            // that only runs when this install performs the disconnect. Deleting and reinstalling
            // the app does NOT: UserDefaults goes, the Keychain stays, and the verifier is written
            // `AfterFirstUnlockThisDeviceOnly`. So a handed-down or resold phone reached a fresh
            // pairing with `hasCustomPIN` already true, and the new family was offered only "change
            // PIN" and "remove PIN" — both of which demand the PREVIOUS family's secret — while the
            // disconnect screen verified against that stale verifier, complete with its persisted
            // lockout. Pairing is precisely the moment that authority transfers, so it is where the
            // old secret has to go.
            SettingsProtectionController.wipePersistedPINState(userDefaults: userDefaults)
        }
    }

    func clearSession() {
        // End any live microphone/camera session FIRST, whoever asked for the disconnect.
        //
        // This used to live at one call site only — `RootView`'s `.oilaSessionInvalidated` handler,
        // i.e. the PARENT-initiated unpair. The child-initiated Disconnect in Settings (behind the
        // parent PIN) called `clearSession()` directly and tore down nothing, so the LiveKit room
        // kept publishing on a token that had already been minted: a microphone outliving the
        // authorization to use it, until the server lease happened to expire. Teardown belongs to
        // the session ending, not to one of the two ways of ending it.
        Task { @MainActor in DeviceAudioStreamManager.shared.stopByChild() }
        // Take down the "your parent sent a message" banner with the session. Left behind, it would
        // sit on the lock screen of a device that is no longer paired — and tapping it would open a
        // chat that belongs to a family this phone is no longer part of.
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [LocalNotificationID.chatMessage])
        center.removeDeliveredNotifications(withIdentifiers: [LocalNotificationID.chatMessage])
        setDSN(nil)
        setAPIAccessToken(nil)
        setAPIRefreshToken(nil)
        setChildAvatarEmoji(nil)
        setChildProfileColor(nil)
        // Wipe the live oila360 device credential too. `secureTokens` only holds the (unused)
        // legacy account tokens; the Bearer token minted by `POST /device/pair` lives in the
        // separate `deviceTokens` slots, and leaving it behind meant a server-side unpair (or a
        // spurious 401) returned the child to pairing while a still-valid token lingered in the
        // Keychain.
        deviceTokens.clear()
        // Disconnect returns the child to the setup flow.
        setSetupCompleted(false)
        setOnboardingCompleted(false)
        setOilaPaired(false)
        purgeChildScopedData()
    }

    /// Wipes every per-child artifact on disconnect so re-pairing this device to a DIFFERENT child
    /// cannot surface the previous child's data. DSN-scoped stores (tasks, chat, dashboard cache,
    /// geo queue) are isolated by regenerating the device DSN — the next pair mints a fresh scope —
    /// while the globally-keyed caches are cleared here directly.
    ///
    /// The product requirement this now satisfies is stronger than "isolate": Ibrohim asked for
    /// "yangi ilova o'rnatilgan holatga qaytarib qo'yasiz" — the state of a freshly installed app.
    /// Regenerating the DSN only makes the previous child's data unreachable; it leaves it on disk,
    /// and several of the artifacts below are not DSN-scoped at all and were reachable by the NEXT
    /// family. Steps 8–12 are the difference between the two readings.
    ///
    /// NOT cleared, on purpose: the Family Controls / Screen Time authorization. Revoking it would
    /// force the next parent through a full re-authorization (an OS prompt that can only be answered
    /// with the parent's own Apple ID password) even when they are re-pairing the SAME child minutes
    /// later. Whether a disconnect should cost that is a product call nobody has made, so this code
    /// does not make it silently.
    private func purgeChildScopedData() {
        // 1. Regenerate the generate-once device DSN → all DSN-scoped stores start empty on re-pair.
        OilaDeviceIdentity.resetDSN(userDefaults: userDefaults)
        // 2. Clear the globally-keyed SettingsCacheStore (not DSN-scoped), so the previous child's
        //    cached connected-device list can't surface before a refresh. (profileName is left as
        //    is — it is not shown while unpaired and is overwritten by the next pair.)
        for key in ["SETTINGS_CACHE_PROFILE_NAME", "SETTINGS_CACHE_CONNECTED_DEVICES"] {
            userDefaults.removeObject(forKey: key)
        }
        // 3. Clear the settings/disconnect PIN and its lockout. The verifier lives device-globally
        //    in the Keychain, so it used to survive an unpair: the NEXT family inherited a PIN only
        //    the previous parent knew, could not clear it without that secret, and the previous
        //    owner kept on-device disconnect authority over another family's child.
        SettingsProtectionController.wipePersistedPINState(userDefaults: userDefaults)
        Task { @MainActor in SettingsProtectionController.shared.refreshAvailability() }
        // 4. Clear the one-time microphone consent. It is device-global and not DSN-scoped, so
        //    child A's consent would otherwise authorize listening on child B after a handover —
        //    with no sheet shown, because the grant short-circuits the prompt.
        //    Both halves go: the camera grant is worthless on its own (a video session needs the
        //    audio grant too), but leaving it behind means a re-consent for audio alone could be
        //    read back as covering video by any future code that checks the flags separately.
        userDefaults.removeObject(forKey: "OILA_AUDIO_CONSENT_GRANTED")
        userDefaults.removeObject(forKey: "OILA_VIDEO_CONSENT_GRANTED")
        // 5. Drop any pending removal-attempt reports. The queue survives relaunches by design, but
        //    `POST /device/apps/removal-attempt` carries no dsn — the server attributes the report to
        //    whichever device Bearer is held when it finally flushes. A report queued for the previous
        //    child would therefore reach the NEXT family with the previous child's app names in it.
        //    Keyed device-globally in `UserDefaults.standard`, which is the same store
        //    `DeviceApplicationRemovalAttemptCoordinator` persists to in production.
        userDefaults.removeObject(forKey: "DEVICE_APPLICATION_REMOVAL_ATTEMPT_QUEUE")
        //    Also the marker recording that iOS's one-time Always-location upgrade prompt has been
        //    issued. It gates the C5 "Enable" button between prompting and opening Settings, and a
        //    handed-down phone should get the prompt again rather than being sent straight to
        //    Settings for a decision the previous family made.
        userDefaults.removeObject(forKey: LocationPermissionManager.alwaysPromptIssuedKey)
        // 6. Same leak, same reasoning, for the queued app-usage batches: they carry the previous
        //    child's package names and seconds, and `POST /device/apps/usage` carries no dsn either.
        userDefaults.removeObject(forKey: "DEVICE_APPLICATION_USAGE_REPORT_STATE")
        // 7. Both queues live in long-lived actors whose IN-MEMORY copies would otherwise survive the
        //    disconnect and persist themselves straight back over steps 5 and 6.
        Task {
            await DeviceApplicationRemovalAttemptCoordinator.shared.purge()
            await DeviceApplicationUsageReportCoordinator.shared.purge()
        }
        // 8. The child's own NAME. The old comment here claimed it was safe to keep because "it is
        //    overwritten by the next pair" — it is not: `BolajonSetupFlowView.handlePaired` falls
        //    back to `sessionStore.profileName` when `POST /device/pair` returns a child with no
        //    name, and the Success screen and Home header render it. A second family could therefore
        //    meet the previous child's name on the screen that welcomes them.
        userDefaults.removeObject(forKey: Keys.profileName)
        profileName = L10n.tr("common.user_default")
        // 9. The whole App Group container. It holds the Screen Time usage snapshot and its multi-day
        //    history, the app-limit snapshot and the queue of pending control events — none of it
        //    DSN-scoped in a way the regeneration reaches, all of it written by an EXTENSION that
        //    keeps running on its own schedule. A per-key sweep here would rot the moment the
        //    extension adds a key, so the suite goes wholesale.
        if let appGroupDefaults {
            appGroupDefaults.removePersistentDomain(forName: appGroupIdentifier)
            // …except the language mirror, which is not child data. The extension reads it to
            // localize its system notifications and has no other source; dropping it would silently
            // switch those notifications to the DEVICE language, which is the exact bug the mirror
            // was added to fix.
            appGroupDefaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
        }
        // 10. DSN-scoped app-lock keys. Regenerating the DSN orphans these rather than deleting
        //     them: the blob naming the previous child's blocked apps stays on disk forever under a
        //     scope nothing will ever read again. Swept by PREFIX, so this also collects the orphans
        //     left by every previous disconnect, not just this one.
        for prefix in ["DEVICE_APP_LOCK_SELECTION_", "DEVICE_APP_LOCK_LOCKED_IDENTIFIERS_"] {
            for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                userDefaults.removeObject(forKey: key)
            }
        }
        // 11. The FCM registration token. The server still maps it to the device record this
        //     disconnect just abandoned, and `RootView.syncPushToken` re-uploads whatever is stored
        //     here at the next pair — so the ghost device and the new one would claim the same push
        //     address. A fresh token arrives from Firebase on the next registration anyway.
        userDefaults.removeObject(forKey: FCMPushRegistrar.fcmTokenDefaultsKey)
        // 12. The telemetry outboxes. `OilaTelemetryService.stop()` already drops these — but it is
        //     guarded on `isRunning`, and telemetry only starts once onboarding is complete AND the
        //     install is paired. A device that queued an SOS or a location fix and then disconnected
        //     without telemetry ever running kept both, and neither payload carries a dsn: whatever
        //     Bearer token is held when the queue finally flushes is who the server attributes it to.
        userDefaults.removeObject(forKey: "OILA_PENDING_SOS")
        userDefaults.removeObject(forKey: "OILA_PENDING_LOCATION_FIXES")
    }

    private static func defaultLanguage(userDefaults: UserDefaults) -> AppLanguage {
        if let persisted = userDefaults.string(forKey: Keys.appLanguage),
           let value = AppLanguage(rawValue: persisted) {
            return value
        }
        return AppLanguage.defaultForDevice
    }

    private let userDefaults: UserDefaults
    private let secureTokens: SecureTokenStoring
    private let deviceTokens: SecureTokenStoring
    /// The `group.…` container the Screen Time extension, the app-limit snapshot and the pending
    /// control events share with the app. `appGroupDefaults` is nil only when the suite cannot be
    /// opened (a missing entitlement); the identifier is kept because the purge removes the domain
    /// by name.
    private let appGroupIdentifier: String
    private let appGroupDefaults: UserDefaults?

    var hasLinkedChildDevice: Bool {
        dsn?.trimmedNonEmpty != nil
    }

    var hasAuthenticatedSession: Bool {
        apiAccessToken?.trimmedNonEmpty != nil || apiRefreshToken?.trimmedNonEmpty != nil
    }

    private func normalizeAccessToken(_ token: String?) -> String? {
        guard let token = token?.trimmedNonEmpty else { return nil }
        let parts = token
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

#if DEBUG
    private static func debugThemeLog(_ message: String) {
        print("[ThemeDebug][SessionStore] \(message)")
    }
#endif
}

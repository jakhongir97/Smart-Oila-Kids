import XCTest
@testable import SmartOilaKids

/// Build 26: the parent's unpair PIN lives on the SERVER. The product owner's rule (2026-09-23):
/// "UZISH qilganda siz PIN so'raysiz doim. PIN olib API ga zapros berasiz. Success kelsa uzasiz aks
/// holda yo'q." These pin that rule where it is decided — `UnpairScreenAction` — and the removal of
/// the build-25 LOCAL PIN.
final class UnpairScreenActionTests: XCTestCase {
    /// The only two answers that may reset the phone.
    func testOnlyAServerYesOrAnAbsentCredentialResets() {
        XCTAssertEqual(UnpairScreenAction.decide(.revoked), .reset)
        XCTAssertEqual(UnpairScreenAction.decide(.credentialAbsent), .reset,
                       "no credential at all means no retry can ever reach the server")
    }

    /// "aks holda yo'q" — every other answer keeps the phone paired.
    func testEveryOtherAnswerKeepsThePhonePaired() {
        let others: [OilaUnpairOutcome] = [
            .pinRequired, .rateLimited, .unreachable, .noCredential, .credentialRejected, .routeMissing, .rejected,
        ]
        for outcome in others {
            if case .reset = UnpairScreenAction.decide(outcome) {
                XCTFail("\(outcome) must not disconnect the phone")
            }
        }
    }

    func testAWrongPINClearsTheDigitsAndSaysSo() {
        XCTAssertEqual(UnpairScreenAction.decide(.pinRequired),
                       .stay(messageKey: "disconnect2.pin_incorrect", clearDigits: true))
        XCTAssertEqual(UnpairScreenAction.decide(.rateLimited),
                       .stay(messageKey: "disconnect2.rate_limited", clearDigits: true))
    }

    /// The parent typed the PIN right and the network failed: keep the digits so a retry is one tap.
    func testOfflineKeepsTheDigits() {
        XCTAssertEqual(UnpairScreenAction.decide(.unreachable),
                       .stay(messageKey: "disconnect2.offline", clearDigits: false))
    }

    /// Every message the mapping can name must exist in the app's strings (all three languages share
    /// one key set, enforced by `scripts/check_localization_parity.py`).
    func testEveryMessageKeyResolves() {
        let all: [OilaUnpairOutcome] = [
            .revoked, .credentialAbsent, .pinRequired, .rateLimited, .unreachable, .noCredential,
            .credentialRejected, .routeMissing, .rejected,
        ]
        for outcome in all {
            guard case let .stay(key, _) = UnpairScreenAction.decide(outcome) else { continue }
            XCTAssertNotEqual(L10n.tr(key), key, "\(key) must resolve to real copy")
        }
    }
}

final class LegacyLocalPINCleanupTests: XCTestCase {
    func testThePurgeDeletesTheBuild25VerifierAndItsKeys() {
        let suiteName = "LegacyPINCleanup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = KeychainPINCredentialStore()
        store.save(Data("build-25-verifier".utf8))
        for key in LegacyLocalPINCleanup.legacyKeys { defaults.set(true, forKey: key) }
        XCTAssertNotNil(store.load(), "precondition: a build-25 verifier is present")

        LegacyLocalPINCleanup.purge(userDefaults: defaults)

        XCTAssertNil(store.load())
        for key in LegacyLocalPINCleanup.legacyKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must be gone")
        }
    }

    /// The purge must not touch the ladder: a lockout the child ran up on build 25 keeps running.
    func testThePurgeLeavesARunningLockoutAlone() {
        let suiteName = "LegacyPINCleanupLadder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(3, forKey: UnpairPINThrottle.failCountKey)

        LegacyLocalPINCleanup.purge(userDefaults: defaults)

        XCTAssertEqual(defaults.integer(forKey: UnpairPINThrottle.failCountKey), 3)
    }
}

/// Pairing is when authority over the device transfers. Anything the previous family left behind has
/// to go with it -- the unpair path clears the verifier, but deleting and reinstalling the app does
/// not: UserDefaults is wiped and the Keychain is not.
@MainActor
final class PairingClearsPreviousFamilyPINTests: XCTestCase {
    func testPairingWipesAPINVerifierLeftBehindByAPreviousInstall() {
        let suiteName = "PairingClearsPIN.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A build-25 local verifier, exactly as a reinstall would leave it: Keychain-resident, with a
        // persisted unpair lockout in the defaults the new install would then inherit.
        let store = KeychainPINCredentialStore()
        store.save(Data("previous-family-verifier".utf8))
        defaults.set(3, forKey: UnpairPINThrottle.failCountKey)
        XCTAssertNotNil(store.load(), "precondition: the stale verifier is present")

        SessionStore(userDefaults: defaults).setOilaPaired(true)

        XCTAssertNil(store.load(), "the build-25 local PIN verifier must not survive a new pairing")
        XCTAssertNil(
            defaults.object(forKey: UnpairPINThrottle.failCountKey),
            "nor its lockout, which would rate-limit the new family out of their own device"
        )
    }
}

/// `clearSession()` is what a disconnect actually means. Its unglamorous half — revoking the device
/// credential and the PIN, and resetting the DSN so a re-pair cannot surface the previous child's
/// data — had no assertions at all: the existing coverage exercised the flags around it.
///
/// The bar is now higher than "the next family cannot reach it". Ibrohim asked for the state of a
/// freshly installed app, and several of the artifacts below were not merely unreachable — they were
/// reachable, by the NEXT family, on the screen that welcomes them.
@MainActor
final class ClearSessionRevokesAuthorityTests: XCTestCase {
    func testDisconnectRevokesTheDeviceCredentialAndEveryChildScopedArtifact() {
        let suiteName = "ClearSessionRevokes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A private stand-in for the App Group. The real suite is shared with a running extension
        // and with other tests, and this purge wipes whatever it is handed.
        let groupSuiteName = "ClearSessionRevokesGroup.\(UUID().uuidString)"
        let groupDefaults = UserDefaults(suiteName: groupSuiteName)!
        defer { groupDefaults.removePersistentDomain(forName: groupSuiteName) }

        // A device mid-session: paired, onboarded, with a PIN and cached child data.
        let store = SessionStore(userDefaults: defaults, appGroupIdentifier: groupSuiteName)
        store.setOilaPaired(true)
        store.setSetupCompleted(true)
        store.setOnboardingCompleted(true)
        store.setLanguage(.ru)
        store.setProfileName("Abdulfattoh")
        defaults.set("Joxon", forKey: "SETTINGS_CACHE_PROFILE_NAME")
        defaults.set("[]", forKey: "SETTINGS_CACHE_CONNECTED_DEVICES")
        KeychainPINCredentialStore().save(Data("family-pin".utf8))
        defaults.set(2, forKey: UnpairPINThrottle.failCountKey)
        // The artifacts that used to survive a disconnect, keyed exactly as production writes them.
        groupDefaults.set(Data("usage".utf8), forKey: "SCREEN_TIME_USAGE_SNAPSHOT_CHILD-1")
        groupDefaults.set(Data("history".utf8), forKey: "SCREEN_TIME_USAGE_HISTORY_SNAPSHOT_CHILD-1_2026-08-18")
        groupDefaults.set(Data("limits".utf8), forKey: "DEVICE_APP_LIMIT_SNAPSHOT_CHILD-1")
        groupDefaults.set(Data("events".utf8), forKey: "DEVICE_CONTROL_PENDING_EVENTS")
        defaults.set(Data("selection".utf8), forKey: "DEVICE_APP_LOCK_SELECTION_child-1")
        defaults.set(["uz.smartoila.game"], forKey: "DEVICE_APP_LOCK_LOCKED_IDENTIFIERS_child-1")
        defaults.set("fcm-registration-token", forKey: FCMPushRegistrar.fcmTokenDefaultsKey)
        defaults.set(Data("sos".utf8), forKey: "OILA_PENDING_SOS")
        defaults.set(Data("fixes".utf8), forKey: "OILA_PENDING_LOCATION_FIXES")
        let dsnBefore = OilaDeviceIdentity.deviceDSN(userDefaults: defaults)

        store.clearSession()

        XCTAssertFalse(store.oilaPaired, "the child is no longer paired")
        XCTAssertFalse(store.setupCompleted, "and is returned to the setup flow")
        XCTAssertNil(
            KeychainPINCredentialStore().load(),
            "the PIN verifier is device-global in the Keychain — leaving it hands the next family a secret only the previous parent knows"
        )
        XCTAssertNil(defaults.object(forKey: UnpairPINThrottle.failCountKey))
        XCTAssertNil(defaults.object(forKey: "SETTINGS_CACHE_PROFILE_NAME"),
                     "the previous child's name must not survive into the next pairing")
        XCTAssertNil(defaults.object(forKey: "SETTINGS_CACHE_CONNECTED_DEVICES"))
        XCTAssertNotEqual(
            OilaDeviceIdentity.deviceDSN(userDefaults: defaults),
            dsnBefore,
            "the DSN is regenerated, which is what makes every DSN-scoped store start empty on re-pair"
        )

        // The child's name. `BolajonSetupFlowView` reads it back when a pair response carries no
        // name, so a second family would be greeted by the first child's name.
        XCTAssertNil(defaults.object(forKey: SessionStore.profileNameDefaultsKey))
        XCTAssertNotEqual(store.profileName, "Abdulfattoh")

        // The App Group, wholesale: usage, its history, the app-limit snapshot, pending control
        // events. All written by an extension that keeps running on its own schedule.
        for key in ["SCREEN_TIME_USAGE_SNAPSHOT_CHILD-1",
                    "SCREEN_TIME_USAGE_HISTORY_SNAPSHOT_CHILD-1_2026-08-18",
                    "DEVICE_APP_LIMIT_SNAPSHOT_CHILD-1",
                    "DEVICE_CONTROL_PENDING_EVENTS"] {
            XCTAssertNil(groupDefaults.object(forKey: key), "\(key) must not survive a disconnect")
        }
        // …but the language mirror is not child data, and the extension has no other source for it.
        XCTAssertEqual(groupDefaults.string(forKey: "APP_LANGUAGE"), AppLanguage.ru.rawValue,
                       "wiping the mirror would silently switch extension notifications to the device language")

        // DSN-scoped app-lock keys are ORPHANED by the DSN regeneration, not deleted — the blob
        // naming the previous child's blocked apps would otherwise sit on disk forever.
        XCTAssertNil(defaults.object(forKey: "DEVICE_APP_LOCK_SELECTION_child-1"))
        XCTAssertNil(defaults.object(forKey: "DEVICE_APP_LOCK_LOCKED_IDENTIFIERS_child-1"))

        // The push address the server still maps to the abandoned device record.
        XCTAssertNil(defaults.object(forKey: FCMPushRegistrar.fcmTokenDefaultsKey))

        // The telemetry outboxes. `OilaTelemetryService.stop()` drops these, but it is guarded on
        // `isRunning` — and telemetry never started here, which is exactly the leak.
        XCTAssertNil(defaults.object(forKey: "OILA_PENDING_SOS"))
        XCTAssertNil(defaults.object(forKey: "OILA_PENDING_LOCATION_FIXES"))

        // No build-25 local-PIN state survives either.
        for key in LegacyLocalPINCleanup.legacyKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must not survive a disconnect")
        }
    }
}

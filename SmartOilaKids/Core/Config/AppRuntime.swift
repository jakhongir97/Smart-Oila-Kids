import Foundation

enum AppRuntime {
    private static let environment = ProcessInfo.processInfo.environment

    static var screenTimeFeaturesEnabled: Bool {
        if let configured = configuredBool("SMARTOILA_SCREEN_TIME_FEATURES_ENABLED") {
            return configured
        }
        if let configured = Bundle.main.object(forInfoDictionaryKey: "SMARTOILA_SCREEN_TIME_FEATURES_ENABLED") as? NSNumber {
            return configured.boolValue
        }
        if let configured = Bundle.main.object(forInfoDictionaryKey: "SMARTOILA_SCREEN_TIME_FEATURES_ENABLED") as? String,
           let resolved = parseBool(configured) {
            return resolved
        }
        return false
    }

    static var showGeoDebugOverlay: Bool {
        configuredBool("SMARTOILA_SHOW_GEO_DEBUG_OVERLAY") ?? false
    }

    /// Parent↔child chat surface (REST + `/ws/chat`). Ships ON: `SMARTOILA_CHAT_FEATURES_ENABLED`
    /// is `true` in Info.plist, so DEBUG and Release now behave identically instead of chat being a
    /// debug-only surface. A `SMARTOILA_CHAT_FEATURES_ENABLED` environment variable still wins over
    /// the bundled value, which is how a tester turns chat off without editing the plist.
    static var chatFeaturesEnabled: Bool {
        featureFlag("SMARTOILA_CHAT_FEATURES_ENABLED")
    }

    /// Live-audio publishing (LiveKit) from the child device. **ON in the shipping Info.plist**
    /// (`SMARTOILA_MEDIA_FEATURES_ENABLED` = `true`) — it reads as a flag because enabling mic
    /// capture is a deliberate, reviewed step (App Store Guideline 5.1.2), which also requires a
    /// visible "parent is listening" indicator + child disclosure and the mic usage string.
    ///
    /// While it is off, a `stream.start` push is still ROUTED by `PushCommandRouter` and only then
    /// discarded by `DeviceAudioStreamManager`. That drop is recorded as `audio_start_dropped_flag_off`
    /// in `RuntimeDiagnosticsCenter.media`, so "the parent pressed listen and nothing happened" can be
    /// told apart from "the push never arrived" without flipping this flag to find out.
    static var audioStreamingEnabled: Bool {
#if DEBUG
        // Configuring a dev-stream secret is an unambiguous "I am testing the LiveKit path right
        // now", so it turns the feature on by itself rather than making the tester remember a
        // second variable. Release is unaffected — `devStreamSecret` does not exist there.
        if devStreamSecret != nil { return true }
#endif
        return featureFlag("SMARTOILA_MEDIA_FEATURES_ENABLED")
    }

    static var debugRoute: DebugRoute? {
#if DEBUG
        guard let value = trimmed("SMARTOILA_DEBUG_ROUTE") else { return nil }
        return DebugRoute(rawValue: value)
#else
        return nil
#endif
    }

    static var hasDebugRoute: Bool {
        debugRoute != nil
    }

    static var debugSetupStep: DebugSetupStep? {
#if DEBUG
        guard let value = trimmed("SMARTOILA_DEBUG_SETUP_STEP") else { return nil }
        return DebugSetupStep(rawValue: value)
#else
        return nil
#endif
    }

    static var debugDSN: String? {
#if DEBUG
        return trimmed("SMARTOILA_DEBUG_DSN")
#else
        return nil
#endif
    }

    static var debugProfileName: String? {
#if DEBUG
        return trimmed("SMARTOILA_DEBUG_PROFILE")
#else
        return nil
#endif
    }

    /// Screenshot-only override for the Home header's link chip.
    ///
    /// The chip is computed from real state — a Keychain credential and a recent successful contact
    /// with the backend — and a screenshot simulator has neither, so every captured Home shot showed
    /// a red "Not connected right now". That is an accurate reading of the simulator and a terrible
    /// primary App Store screenshot: the one image a shopper sees says the product is not working.
    ///
    /// This is the same class of hook the capture script already relies on for the SOS sheet and the
    /// live-session banner (`SMARTOILA_DEBUG_SOS`, `SMARTOILA_DEBUG_INDICATOR`) — it makes an
    /// ordinary state reachable in a simulator that cannot reach a server. It is **not** a
    /// store-review mode: it is `#if DEBUG`, so it cannot exist in the archive App Review installs,
    /// and it changes nothing for any user. Deliberately kept that way after the `storeReviewMode`
    /// removal, which was about showing REVIEWERS different behaviour than families get.
    static var debugLinkHealthy: Bool {
#if DEBUG
        return trimmed("SMARTOILA_DEBUG_LINK_HEALTHY") == "1"
#else
        return false
#endif
    }

#if DEBUG
    // MARK: Dev live-audio testing
    //
    // The backend exposes `POST /api/v1/dev/streaming/token` — "Dev/test only: mint a LiveKit token
    // (X-Dev-Secret required)" — which mints against an arbitrary room/identity with NO device
    // Bearer. That lets the real microphone → LiveKit → listener path be proven on a physical device
    // without a paired session, without Firebase, and without the audio wake push (whose event name
    // the backend has not defined yet). DEBUG-only by construction: none of this compiles in Release.

    /// The `X-Dev-Secret` header value. Ask the backend owner for it; never commit it.
    static var devStreamSecret: String? {
        trimmed("SMARTOILA_DEV_STREAM_SECRET")
    }

    /// LiveKit room to publish into. The listener must mint a `subscriber` token for the SAME room.
    static var devStreamRoom: String {
        trimmed("SMARTOILA_DEV_STREAM_ROOM") ?? "bolajon-dev"
    }

    /// Participant identity for this device inside the room.
    static var devStreamIdentity: String {
        trimmed("SMARTOILA_DEV_STREAM_IDENTITY") ?? "child-ios"
    }
#endif

}

enum DebugRoute: String {
    case bolajonSetup = "setup"
    case bolajonPermissions = "perm2"
    case bolajonHome = "home2"
    case bolajonTasks = "tasks2"
    case bolajonChat = "chat2"
    case bolajonSettings = "settings2"
}

enum DebugSetupStep: String {
    case language
    case welcome
    case connect
    case success
}

private extension AppRuntime {
    /// Resolve a boolean feature flag the same way `screenTimeFeaturesEnabled` does:
    /// process env first (for tests/CI), then Info.plist as an `NSNumber` or a `String`.
    /// Defaults to `false` when unset — features stay dormant unless explicitly turned on.
    static func featureFlag(_ key: String) -> Bool {
        if let configured = configuredBool(key) {
            return configured
        }
        if let number = Bundle.main.object(forInfoDictionaryKey: key) as? NSNumber {
            return number.boolValue
        }
        if let string = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let resolved = parseBool(string) {
            return resolved
        }
        return false
    }

    static func configuredBool(_ key: String) -> Bool? {
        guard let value = trimmed(key) else { return nil }
        return parseBool(value)
    }

    static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    static func trimmed(_ key: String) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

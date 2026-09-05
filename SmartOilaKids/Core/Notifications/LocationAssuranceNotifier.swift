import CoreLocation
import Foundation
import UserNotifications

/// Tells the CHILD, on their own phone, that their location has stopped being useful.
///
/// Everything else built for this problem reports upward: `diagnostics` tells the backend, which
/// tells the parent, who then has to reach the child and explain which switch to move. That loop is
/// days long, and it is why the same complaint kept coming back — by the time anyone knew, the trail
/// had been broken for a week. The child is standing next to the setting. Ask them.
///
/// Three states qualify, and each is silent by nature — none of them shows an error, a crash, or an
/// offline badge anywhere in the app:
///
/// - **`backgroundDenied`** — "While Using the App". Almost always the iOS background-usage reminder
///   ("Bolajon360 has used your location 11 times in the background… Continue to allow?") answered
///   with "Change to Only While Using". iOS shows that prompt on its own schedule, the child taps it
///   in a second, and nothing in the app ever mentions it again: `requestAlwaysAuthorization` is a
///   permanent no-op after the first refusal (`CLLocationManager.h:502-506`), so the app cannot
///   re-ask and Settings is the only route back.
/// - **`denied`** — the app, or the whole device, has location off.
/// - **`reducedAccuracy`** — Always is granted and Precise Location is not. The rarest to notice and
///   the most misleading: everything reports healthy while every fix is 1–5 km wide.
///
/// The notification needs alert authorization, which is optional in this app. When it is absent the
/// evaluation is still recorded, so the permission screen and the `diagnostics` map remain the
/// backstop; nothing here is the only copy of the news.
enum LocationAssuranceReason: String, CaseIterable {
    case backgroundDenied = "location_background_denied"
    case denied = "location_denied"
    case reducedAccuracy = "location_reduced_accuracy"

    var titleKey: String {
        switch self {
        case .backgroundDenied: return "notifications.location_assurance.background_denied_title"
        case .denied: return "notifications.location_assurance.denied_title"
        case .reducedAccuracy: return "notifications.location_assurance.reduced_accuracy_title"
        }
    }

    var bodyKey: String {
        switch self {
        case .backgroundDenied: return "notifications.location_assurance.background_denied_body"
        case .denied: return "notifications.location_assurance.denied_body"
        case .reducedAccuracy: return "notifications.location_assurance.reduced_accuracy_body"
        }
    }
}

enum LocationAssuranceNotifier {
    /// At most one reminder a day for the same reason. A child who has decided to leave the setting
    /// alone is not going to be persuaded by the fourth banner, and a nagging app is one a child
    /// removes — which costs the parent everything, not just the trail.
    static let repeatInterval: TimeInterval = 24 * 60 * 60

    static let lastReasonKey = "OILA_LOCATION_ASSURANCE_REASON"
    static let lastNotifiedAtKey = "OILA_LOCATION_ASSURANCE_AT"

    /// What is wrong, or nil when nothing is. Pure, so every combination is testable without a
    /// device or a permission prompt.
    ///
    /// `.restricted` returns nil deliberately: it is a Screen Time or MDM restriction the child
    /// cannot lift, so a banner telling them to open Settings would be advice that cannot be
    /// followed. It still travels to the parent as `location: unavailable` in `diagnostics`, where
    /// it can reach someone who CAN act on it.
    static func reason(
        authorization: CLAuthorizationStatus,
        accuracy: CLAccuracyAuthorization
    ) -> LocationAssuranceReason? {
        switch authorization {
        case .authorizedAlways:
            return accuracy == .reducedAccuracy ? .reducedAccuracy : nil
        case .authorizedWhenInUse:
            // Reported ahead of any accuracy problem: background delivery is the bigger loss, and
            // two banners about the same Settings page in one day is how an app gets deleted.
            return .backgroundDenied
        case .denied:
            return .denied
        case .restricted, .notDetermined:
            // `.notDetermined` belongs to onboarding, which asks in context and with a screen to
            // explain it. A push notification is a worse version of a prompt the app is about to
            // show anyway.
            return nil
        @unknown default:
            return nil
        }
    }

    /// Rate limiting, split out for the same reason: it is a rule, not an effect.
    ///
    /// A CHANGE of reason always notifies. Going from "While Using" to "Precise off" is a different
    /// problem with a different fix, and holding it for the rest of the day because something else
    /// was reported this morning would suppress the news exactly when the child has just been in
    /// Settings and is most likely to finish the job.
    static func shouldNotify(
        reason: LocationAssuranceReason,
        lastReason: String?,
        lastNotifiedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard lastReason == reason.rawValue, let lastNotifiedAt else { return true }
        // A stamp in the future is a clock that moved, not a recent notification. Treat it as due
        // rather than letting a mis-set date silence the reminder indefinitely.
        let elapsed = now.timeIntervalSince(lastNotifiedAt)
        return elapsed < 0 || elapsed >= repeatInterval
    }

    /// Evaluate and, if it is due, post. Safe to call on every authorization change.
    static func evaluate(
        authorization: CLAuthorizationStatus,
        accuracy: CLAccuracyAuthorization,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        deliver: (LocationAssuranceReason) -> Void = { post($0) }
    ) {
        guard let reason = reason(authorization: authorization, accuracy: accuracy) else {
            // Resolved. Forget the stamp so that if it happens again next month the child is told
            // straight away instead of being inside a day-long window from the last time.
            defaults.removeObject(forKey: lastReasonKey)
            defaults.removeObject(forKey: lastNotifiedAtKey)
            return
        }

        let storedAt = defaults.double(forKey: lastNotifiedAtKey)
        guard shouldNotify(
            reason: reason,
            lastReason: defaults.string(forKey: lastReasonKey),
            lastNotifiedAt: storedAt > 0 ? Date(timeIntervalSince1970: storedAt) : nil,
            now: now
        ) else { return }

        defaults.set(reason.rawValue, forKey: lastReasonKey)
        defaults.set(now.timeIntervalSince1970, forKey: lastNotifiedAtKey)
        deliver(reason)
    }

    private static func post(_ reason: LocationAssuranceReason) {
        let content = UNMutableNotificationContent()
        content.title = L10n.tr(reason.titleKey)
        content.body = L10n.tr(reason.bodyKey)
        content.sound = .default
        content.userInfo = ["event": reason.rawValue]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "oila.location.assurance." + reason.rawValue,
                content: content,
                trigger: nil
            )
        )
    }
}

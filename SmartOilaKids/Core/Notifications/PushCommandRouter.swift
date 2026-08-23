import Foundation
import UIKit
import UserNotifications
import os

enum PushDeliveryContext: String {
    case direct = "direct"
    case launch = "launch"
    case backgroundFetch = "background_fetch"
    case foregroundPresentation = "foreground_presentation"
    case userResponse = "user_response"
}

enum PushCommandRouter {
    static func handle(
        userInfo: [AnyHashable: Any],
        openedFromInteraction: Bool = false,
        deliveryContext: PushDeliveryContext = .direct
    ) {
        let payload = parsePayload(from: userInfo)
        // The single question a field failure always turns on: did a push arrive at all? Nothing
        // answered it before -- diagnostics went only to an in-memory object no screen reads, so
        // "the parent pressed listen and nothing happened" was indistinguishable from a push that
        // never left Firebase. The event name and delivery context are enough to tell those apart
        // and are not user data; no payload, token or body is logged.
        log.notice(
            "push \(deliveryContext.rawValue, privacy: .public) event=\(payload.event.isEmpty ? "-" : payload.event, privacy: .public) dsn=\(payload.dsn == nil ? "absent" : "present", privacy: .public)"
        )
#if DEBUG
        // Also to stdout, so an on-device test driven from a Mac can watch it live over
        // `devicectl device process launch --console`, which captures stdout but not os_log.
        print("[oila] push \(deliveryContext.rawValue) event=\(payload.event)")
#endif
        updateDiagnostics(
            status: openedFromInteraction ? "opened" : "received",
            dsn: payload.dsn ?? "-",
            lastEvent: payload.event.isEmpty ? "-" : payload.event,
            lastRoute: "-",
            deliveryContext: deliveryContext.rawValue
        )
        persistInboxItem(payload, openedFromInteraction: openedFromInteraction)
        applyRouting(
            payload,
            openedFromInteraction: openedFromInteraction,
            deliveryContext: deliveryContext
        )
    }

    static let log = Logger(subsystem: "uz.smartoila.kids", category: "push")

    /// True when `handle(...)` will try to raise the local chat banner for this payload.
    ///
    /// Exists so `didReceiveRemoteNotification` can hold its fetch completion handler for the moment
    /// the banner needs: calling that handler tells iOS the push is finished with, and it may
    /// suspend the process immediately — before the scheduling hop onto the main actor has run, so
    /// the child would get no banner at all. Deliberately does NOT include the app-active check:
    /// that one needs the main actor, and holding the handler an extra beat when no banner turns out
    /// to be needed costs nothing.
    static func schedulesChatBanner(userInfo: [AnyHashable: Any], deliveryContext: PushDeliveryContext) -> Bool {
        guard deliveryContext != .userResponse, deliveryContext != .foregroundPresentation else { return false }
        let payload = parsePayload(from: userInfo)
        guard payload.title?.trimmedNonEmpty == nil, payload.body?.trimmedNonEmpty == nil else { return false }
        return containsAny(in: payload.routingHaystack, tokens: RoutingTokens.chat)
    }

    /// A tap on our own "your parent sent a message" banner: open the chat, and nothing else.
    ///
    /// Deliberately not `handle(...)`. That would re-route an app-authored notification as if it
    /// were a fresh server command — the exact re-ingestion `LocalNotificationID` exists to stop.
    /// This does only the part a tap earns: arm the deep link (for a cold launch, where no view is
    /// listening yet) and post the open (for a warm one, where Home is already on screen).
    static func openChatFromLocalBanner(userInfo: [AnyHashable: Any]) {
        let dsn = (userInfo[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty
        saveDeepLink(destination: .chat, dsn: dsn)
        post(.pushShouldOpenChat, dsn: dsn)
        updateDiagnostics(status: "opened", lastRoute: "chat_open_local_banner")
    }
}

private extension PushCommandRouter {
    enum RoutingTokens {
        static let lock = ["lock"]
        static let tasks = ["task", "award"]
        static let chat = ["chat", "message", "sms"]
        /// Audio subject stems, prefix-matched against whole event tokens — never as a raw
        /// substring of the event, because "mic" also sits inside ordinary words like "dynamic".
        static let audioSubjects = ["stream", "audio", "listen", "efir", "tingla", "mic"]
        /// Stop verb stems, prefix-matched against a whole token. Prefix-on-token is what makes
        /// inflections work without reintroducing the substring bug: "stopped"/"ended"/
        /// "disconnected" all START with a stem, while "sending"/"friend" merely CONTAIN "end" and
        /// so never match.
        static let stopVerbs = ["stop", "end", "hangup", "disconnect", "tugat", "cancel", "close"]
        /// Start verb stems, same prefix-on-token rule ("started", "boshlandi").
        static let startVerbs = ["start", "begin", "open", "wake", "resume", "boshla"]
        /// For a GLUED event ("streamaudiostopped") there are no token boundaries to prefix-match,
        /// so these are searched as plain substrings. Only stems that cannot hide inside an
        /// ordinary word qualify — "end" is deliberately absent, which is exactly the trap the
        /// original substring matcher fell into.
        static let gluedStopVerbs = ["stop", "hangup", "disconnect", "tugat", "cancel"]
        static let gluedStartVerbs = ["start", "begin", "wake", "resume", "boshla"]
        /// Verb-less wake events, matched by WHOLE-EVENT equality (never as a substring) — the one
        /// shape allowed to start a stream without naming a start verb. Whole-event equality is
        /// safe because the event field is machine-authored; a parent cannot type into it.
        static let bareAudioStartEvents = [
            "stream", "audio", "listen", "efir", "tingla", "mic",
            "stream.audio", "audio.stream", "streamaudio", "audiostream",
            "stream_audio", "audio_stream", "device.stream", "device_stream"
        ]
        /// Subject stems for the "report your status now" command, prefix-matched against the
        /// event's FIRST token only (see `isStatusReportCommand`). "holat" is the Uzbek word the
        /// backend logs already use for this concept.
        static let statusSubjects = ["status", "holat"]
        /// Whole-event aliases where the status subject is not the first token.
        static let statusAliasEvents = ["device.status", "device_status", "devicestatus"]
    }

    /// Shows "your parent sent a message" for a SILENT `chat.refresh`.
    ///
    /// The backend sends chat pushes as data-only messages — the Android child app builds the banner
    /// itself (`FCMService` → `ChatNotification.show`, channel `chat_messages`, IMPORTANCE_HIGH, one
    /// fixed id). iOS displayed nothing at all: a data-only push draws no banner, the inbox row is
    /// deliberately dropped for command pushes, and both `.pushShouldRefreshChat` observers live in
    /// view bodies. So a child whose phone was in their pocket had no way to learn a message had
    /// arrived until they happened to open the app.
    ///
    /// Deliberately narrow:
    ///  • Only when the push carries NO title and NO body of its own. If the backend ever starts
    ///    sending a real alert, iOS renders that and this would be a duplicate.
    ///  • Never while the app is active — the chat screen and the Home badge already update live, and
    ///    a banner over the conversation you are reading is noise.
    ///  • The body is OUR text, never the parent's message. The message content is not in the push
    ///    (and this app deliberately keeps person-authored text off the lock screen and off disk).
    static func presentChatBannerIfNeeded(_ payload: PushCommandPayload, deliveryContext: PushDeliveryContext) {
        // INVARIANT, do not weaken: this runs inside the WIDE-haystack chat block, which matches on
        // the notification title and body — i.e. on the parent's own words. It is only safe because
        // it refuses any push that HAS a title or body. A payload carrying human text is either a
        // real alert (iOS renders it itself) or not a command at all.
        guard payload.title?.trimmedNonEmpty == nil, payload.body?.trimmedNonEmpty == nil else { return }
        guard deliveryContext != .userResponse, deliveryContext != .foregroundPresentation else { return }
        // Addressed to a DIFFERENT device: never raise this child's banner for someone else's
        // message. An absent dsn is accepted — the backend addresses by FCM token and omits it (the
        // same rule `RootView.shouldHandlePush` applies).
        if let pushedDSN = payload.dsn?.trimmedNonEmpty,
           let localDSN = OilaDeviceIdentity.persistedDSN()?.trimmedNonEmpty,
           pushedDSN.caseInsensitiveCompare(localDSN) != .orderedSame {
            return
        }
        let dsn = payload.dsn ?? ""
        Task { @MainActor in
            guard UIApplication.shared.applicationState != .active else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.tr("chat2.notification.title")
            content.body = L10n.tr("chat2.notification.body")
            content.sound = .default
            content.userInfo = [PushUserInfoKeys.dsn: dsn, "event": "chat.refresh"]
            let request = UNNotificationRequest(
                identifier: LocalNotificationID.chatMessage,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    static func persistInboxItem(_ payload: PushCommandPayload, openedFromInteraction: Bool) {
        // A SILENT command push has nothing for a human to read. `stream.start`, `stream.stop`,
        // `lock.refresh`, `chat.refresh` and `status.report` all arrive with no title and no body,
        // and every one of them was writing an unread row. Nothing in the app can render that list
        // or mark it read (`markRead`/`markAllRead` have no production callers), so the child's
        // app-icon badge climbed with every parent action and pointed at a screen that does not
        // exist — unclearable short of deleting the app.
        //
        // Keep the diagnostics trail (recorded by the caller) and drop only the inbox row.
        let title = payload.title?.trimmedNonEmpty
        let body = payload.body?.trimmedNonEmpty
        guard title != nil || body != nil else { return }
        Task {
            await PushInboxStore.shared.append(
                title: payload.title ?? "",
                body: payload.body ?? "",
                event: payload.event,
                dsn: payload.dsn,
                isRead: openedFromInteraction
            )
        }
    }

    static func applyRouting(
        _ payload: PushCommandPayload,
        openedFromInteraction: Bool,
        deliveryContext: PushDeliveryContext
    ) {
        let haystack = payload.routingHaystack
        var deepLinkDestination: PushDeepLinkDestination?
        var routeActions: [String] = []

        // `status.report`: the parent asked for a fresh battery / network reading. Read from the
        // structured command, never the haystack — see `isStatusReportCommand`.
        if isStatusReportCommand(payload.commandHaystack) {
            post(.pushShouldReportStatus, dsn: payload.dsn)
            routeActions.append("status_report")
        }

        if containsAny(in: haystack, tokens: RoutingTokens.lock) {
            post(.pushShouldRefreshLockState, dsn: payload.dsn)
            routeActions.append("lock_refresh")
        }

        if containsAny(in: haystack, tokens: RoutingTokens.tasks) {
            post(.pushShouldRefreshTasks, dsn: payload.dsn)
            routeActions.append("tasks_refresh")
            if openedFromInteraction {
                post(.pushShouldOpenTasks, dsn: payload.dsn)
                deepLinkDestination = .tasks
                routeActions.append("tasks_open")
            }
        }

        if containsAny(in: haystack, tokens: RoutingTokens.chat) {
            post(.pushShouldRefreshChat, dsn: payload.dsn)
            routeActions.append("chat_refresh")
            if openedFromInteraction {
                post(.pushShouldOpenChat, dsn: payload.dsn)
                deepLinkDestination = .chat
                routeActions.append("chat_open")
            }
            presentChatBannerIfNeeded(payload, deliveryContext: deliveryContext)
        }

        // Live-audio wake: the parent tapping "listen" sends a data-push whose EVENT names the
        // stream → start publishing (gated by the flag + one-time consent in the manager); a
        // matching stop event tears the session down. Unlike every block above, this one reads
        // `commandHaystack` (the structured event alone) and never `routingHaystack`: the haystack
        // also carries the notification title/body, and for a chat push the body is the parent's own
        // message, so a parent writing "tingla" was enough to open the child's microphone. The
        // blocks above keep the wide haystack on purpose — they only refresh or deep-link.
        switch audioRoute(forCommand: payload.commandHaystack) {
        case .start where StoreReviewModeStore.shared.isActive:
            // Under App Store review this build hides its covert feature: a live-audio/video wake is
            // dropped rather than opening the mic/camera. Recorded so the reason is visible in
            // diagnostics, never silently swallowed. Reverts automatically when the operator clears
            // review mode for this build (next `app-config` refresh).
            routeActions.append("audio_start_suppressed_store_review")
        case .start:
            // Forward the server-owned lease fields (mode / cameraType / maxDurationSeconds /
            // expiresAt) so the manager can drop a stale (Doze-delayed) command, size its lease, and
            // pick audio-vs-video + camera. Absent fields default safely in the manager (audio-only).
            post(.pushShouldStartAudioStream, dsn: payload.dsn, extra: [
                PushUserInfoKeys.streamMode: payload.streamMode ?? "",
                PushUserInfoKeys.streamCameraType: payload.streamCameraType ?? "",
                PushUserInfoKeys.streamMaxDurationSeconds: payload.streamMaxDurationSeconds ?? "",
                PushUserInfoKeys.streamExpiresAt: payload.streamExpiresAt ?? ""
            ])
            routeActions.append("audio_start")
        case .stop:
            post(.pushShouldStopAudioStream, dsn: payload.dsn)
            routeActions.append("audio_stop")
        case .none:
            break
        }

        // Recording-trigger (covert clip) pushes remain intentionally unrouted — that feature was
        // cut for v1; this block handles only LIVE audio, which is non-covert (indicator + consent).

        if let deepLinkDestination {
            saveDeepLink(destination: deepLinkDestination, dsn: payload.dsn)
        }

        updateDiagnostics(
            status: routeActions.isEmpty ? (openedFromInteraction ? "opened" : "received") : "routed",
            dsn: payload.dsn ?? "-",
            lastEvent: payload.event.isEmpty ? "-" : payload.event,
            lastRoute: routeActions.isEmpty ? "-" : routeActions.joined(separator: ", "),
            deliveryContext: deliveryContext.rawValue
        )
    }

    static func containsAny(in source: String, tokens: [String]) -> Bool {
        tokens.contains { source.contains($0) }
    }

    static func post(_ name: Notification.Name, dsn: String?) {
        post(name, dsn: dsn, extra: [:])
    }

    static func post(_ name: Notification.Name, dsn: String?, extra: [String: Any]) {
        Task { @MainActor in
            var userInfo: [String: Any] = [PushUserInfoKeys.dsn: dsn ?? ""]
            userInfo.merge(extra) { _, new in new }
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        }
    }
}

// MARK: - Live-audio command routing
//
// Deliberately NOT in the private extension above: this is the one routing decision that opens
// hardware, so it is kept internal and directly unit-tested (see PushAudioCommandRoutingTests).

extension PushCommandRouter {
    enum AudioCommandRoute {
        case start
        case stop
    }

    /// Decides whether a push is a live-audio wake, a stop, or neither — from the structured command
    /// (event) alone, because this is the only route that opens hardware.
    ///
    /// The backend event contract is not documented in this repo, so matching stays tolerant WITHIN
    /// the event: the explicit names ("stream.audio.start", "stream.start", "audio.start",
    /// "listen.start" and their .stop/.end counterparts) as well as looser ones ("stream",
    /// "audio_start", "streamAudioStop") all route — but only because the machine-authored event
    /// names the audio subject, never because a human typed "listen" in the message body.
    ///
    /// Two rules make this safe rather than merely tolerant:
    ///
    ///  • STOP WINS, and is matched on a token PREFIX, so every inflection the backend might send
    ///    ("stopped", "ended", "disconnected") still stops the stream. Getting this wrong is the
    ///    dangerous direction: a stop misread as a start opens a microphone at the exact moment the
    ///    parent hung up.
    ///  • It FAILS CLOSED. An audio-subject event with no recognised verb ("stream.audio.failed",
    ///    "audio.token.expired", "stream.status") routes to `nil` — no action — instead of falling
    ///    through to start. A wake that silently does nothing is a bug found in testing; a mic that
    ///    opens on an informational event is a privacy incident on a children's device.
    ///
    /// The one exception to failing closed is a BARE subject event ("stream", "stream.audio"),
    /// matched by whole-event equality: that is the plausible shape of a verb-less wake command,
    /// and whole-event equality cannot be reached by human-authored text.
    ///
    /// Note the parser lowercases the event before it ever gets here, so camelCase humps are
    /// already gone — "streamAudioStop" arrives as one glued token and is handled by the glued
    /// substring pass, which uses only stems that cannot hide inside an ordinary word.
    static func audioRoute(forCommand command: String) -> AudioCommandRoute? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        let tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard tokens.contains(where: { hasStem($0, in: RoutingTokens.audioSubjects) }) else { return nil }

        if tokens.contains(where: { hasStem($0, in: RoutingTokens.stopVerbs) })
            || containsAny(in: normalized, tokens: RoutingTokens.gluedStopVerbs) {
            return .stop
        }
        if tokens.contains(where: { hasStem($0, in: RoutingTokens.startVerbs) })
            || containsAny(in: normalized, tokens: RoutingTokens.gluedStartVerbs) {
            return .start
        }
        if RoutingTokens.bareAudioStartEvents.contains(normalized) { return .start }
        return nil
    }

    /// True when `token` begins with any of `stems` — the matching rule that lets "stopped" count
    /// as "stop" while keeping "sending" from counting as "end".
    static func hasStem(_ token: String, in stems: [String]) -> Bool {
        stems.contains { token.hasPrefix($0) }
    }

    /// True when the push is the backend's "report your status now" command (`status.report`).
    ///
    /// Kept out of the private extension, and read from the structured command rather than the wide
    /// routing haystack, for the same reason as `audioRoute`: this drives a device action, and the
    /// haystack carries the parent's own message text on a chat push.
    ///
    /// Matched on the event's FIRST token so the SUBJECT has to be the status, not merely a word
    /// appearing somewhere in it. That is what keeps `stream.status` — an informational stream
    /// event the D-073 contract can send — from being read as a status command. `device.status` is
    /// allowed as a whole-event alias because a machine-authored event cannot be typed by a human.
    ///
    /// The Android child app answers `status.report` by posting a fresh `/device/status` snapshot
    /// immediately (`FCMService.onMessageReceived` → `SendDeviceStatusUseCase`); iOS routed the
    /// event to `.pushShouldRefreshDashboard`, which no object observes, so the parent's refresh
    /// did nothing until the 300s timer came round.
    static func isStatusReportCommand(_ command: String) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if RoutingTokens.statusAliasEvents.contains(normalized) { return true }
        guard let first = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first else {
            return false
        }
        return hasStem(String(first), in: RoutingTokens.statusSubjects)
    }
}

private extension PushCommandRouter {
    static func saveDeepLink(destination: PushDeepLinkDestination, dsn: String?) {
        Task {
            await PushDeepLinkStore.shared.save(destination: destination, dsn: dsn)
        }
    }

    static func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        lastEvent: String? = nil,
        lastRoute: String? = nil,
        deliveryContext: String? = nil
    ) {
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updatePush(
                status: status,
                dsn: dsn,
                lastEvent: lastEvent,
                lastRoute: lastRoute,
                deliveryContext: deliveryContext
            )
        }
    }
}

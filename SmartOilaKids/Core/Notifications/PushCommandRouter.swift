import Foundation
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
}

private extension PushCommandRouter {
    enum RoutingTokens {
        static let dashboard = ["log", "usage", "geo", "location", "stat", "system"]
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

        if containsAny(in: haystack, tokens: RoutingTokens.dashboard) {
            post(.pushShouldRefreshDashboard, dsn: payload.dsn)
            routeActions.append("dashboard_refresh")
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
        }

        // Live-audio wake: the parent tapping "listen" sends a data-push whose EVENT names the
        // stream → start publishing (gated by the flag + one-time consent in the manager); a
        // matching stop event tears the session down. Unlike every block above, this one reads
        // `commandHaystack` (the structured event alone) and never `routingHaystack`: the haystack
        // also carries the notification title/body, and for a chat push the body is the parent's own
        // message, so a parent writing "tingla" was enough to open the child's microphone. The
        // blocks above keep the wide haystack on purpose — they only refresh or deep-link.
        switch audioRoute(forCommand: payload.commandHaystack) {
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

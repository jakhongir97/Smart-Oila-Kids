import PhotosUI
import SwiftUI
import UIKit

// Bolajon360 Chat (parent ↔ child). Mirrors the Android child chat: peer header with an online
// dot, child bubbles trailing (purple, with sent/read ticks), parent bubbles leading (white),
// an "unread messages" divider, and a pill composer. Wired to the oila360 device chat API
// (`OilaChatServicing`) for history/send/read + `DeviceChatWebSocketService` for realtime receive.
// Gated by `AppRuntime.chatFeaturesEnabled`.

// MARK: - Attachments

/// How an image attachment is being displayed right now.
enum ChatImageSource {
    /// A freshly signed, short-lived URL from `GET /device/chat/messages/{id}/attachment`.
    case remote(URL)
    /// A photo the child just picked, still on its way to the server.
    case local(UIImage)
}

/// Identifies which attachment the full-screen viewer is showing.
private struct ChatImagePreviewItem: Identifiable {
    let id: String
    let source: ChatImageSource
}

/// In-memory-only store of chat image attachments, owned by the chat view model and therefore
/// alive exactly as long as the screen is.
///
/// The backend hands out a **fresh signed URL that expires** for every
/// `GET /device/chat/messages/{id}/attachment` call, so a URL must be fetched on demand and must
/// never be persisted — a stored one both goes stale and leaves a minor's media reachable from
/// disk. Nothing here touches UserDefaults, the Keychain, or the file system on purpose.
@MainActor
final class ChatAttachmentStore: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready(URL)
        case failed
    }

    @Published private(set) var states: [String: LoadState] = [:]
    /// Photos the child picked in this session, keyed by message id — shown immediately for the
    /// optimistic echo and then carried over to the server's message id, so a just-sent photo
    /// never round-trips through the attachment endpoint just to render itself.
    @Published private(set) var previews: [String: UIImage] = [:]

    /// How long a signed URL is assumed to stay usable. `GET .../attachment` returns no expiry, so
    /// this is a deliberately conservative floor for a presigned link: re-minting one costs a
    /// single cheap authenticated GET, while handing `AsyncImage` an expired URL shows the child a
    /// broken photo that only recovers if they notice the retry affordance.
    static let signedURLLifetime: TimeInterval = 4 * 60

    private let chat: OilaChatServicing
    /// Message ids with a request in flight, so a re-entrant `load` (LazyVStack re-appearing the
    /// same row while scrolling) can't fire a second signed-URL request.
    private var inFlight: Set<String> = []
    /// When each `.ready` URL was minted, so an expired one is re-fetched rather than re-served.
    private var issuedAt: [String: Date] = [:]

    init(chat: OilaChatServicing = OilaDeviceClient.shared) {
        self.chat = chat
    }

    func state(for messageID: String) -> LoadState? { states[messageID] }
    func preview(for messageID: String) -> UIImage? { previews[messageID] }

    /// Fetches the signed URL once per message. `force` is the tap-to-retry path: it discards the
    /// previous outcome (including a URL that has since expired) and asks for a brand new one.
    func load(_ messageID: String, force: Bool = false) {
        // A locally-previewed photo is already on screen; there is nothing to download.
        guard previews[messageID] == nil else { return }
        guard !inFlight.contains(messageID) else { return }
        if !force, !needsRefresh(messageID) { return }

        inFlight.insert(messageID)
        states[messageID] = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.chat.fetchChatAttachmentURL(messageId: messageID)
                self.states[messageID] = .ready(url)
                self.issuedAt[messageID] = Date()
            } catch {
                self.states[messageID] = .failed
                self.issuedAt[messageID] = nil
            }
            self.inFlight.remove(messageID)
        }
    }

    func retry(_ messageID: String) { load(messageID, force: true) }

    /// Re-mints every signed URL that has outlived its lifetime — called when the screen comes
    /// back to the foreground, so a thread that sat backgrounded past the expiry does not come
    /// back full of photos that only load again after the child taps each one.
    func refreshExpired() {
        for messageID in Array(states.keys) where needsRefresh(messageID) {
            load(messageID, force: true)
        }
    }

    /// True when nothing has been fetched for this message yet, or when the URL that WAS fetched
    /// has outlived its assumed signature lifetime. A `.failed` state deliberately does not
    /// expire: that one stays behind tap-to-retry, exactly as before.
    private func needsRefresh(_ messageID: String) -> Bool {
        guard let state = states[messageID] else { return true }
        guard case .ready = state, let issued = issuedAt[messageID] else { return false }
        return Date().timeIntervalSince(issued) >= Self.signedURLLifetime
    }

    func setPreview(_ image: UIImage, for messageID: String) {
        previews[messageID] = image
    }

    /// Re-keys a just-sent photo from its local echo id to the id the server assigned it.
    func movePreview(from localID: String, to serverID: String) {
        guard let image = previews.removeValue(forKey: localID) else { return }
        previews[serverID] = image
    }

    func clearPreview(for messageID: String) {
        previews[messageID] = nil
    }
}

/// A photo picked in the composer and prepared for upload, plus the thumbnail shown while it
/// waits there.
struct PendingChatImage {
    let data: Data
    let preview: UIImage
}

/// Prepares a picked photo for upload. A 12MP original is several megabytes, and on the mobile
/// connections this app actually runs on that upload times out, so the image is downscaled on its
/// long edge and re-encoded as JPEG *before* it ever reaches the multipart body.
enum ChatImagePreparer {
    static let maxDimension: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.8

    /// Deliberately synchronous and free of any actor isolation so the caller can run it off the
    /// main actor (decoding a full-resolution photo costs hundreds of milliseconds). Returns nil
    /// when the picked item isn't a decodable image.
    static func jpegData(from original: Data) -> Data? {
        guard let image = UIImage(data: original) else { return nil }
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > 0 else { return nil }

        let scale = min(1, maxDimension / longEdge)
        let targetSize = CGSize(width: max(1, (image.size.width * scale).rounded()),
                                height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        // Points == pixels: the source is already at full resolution, and letting the renderer
        // apply the screen scale would silently multiply the output back up to ~3× the target.
        format.scale = 1
        // JPEG carries no alpha channel anyway, and an opaque context is cheaper to draw into.
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            // `draw(in:)` honours the photo's EXIF orientation, so a portrait shot doesn't arrive
            // sideways at the parent.
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: jpegQuality)
    }
}

/// Delivery state of a bubble the child sent, driving the tick / spinner / retry affordance.
enum ChatDeliveryState: Equatable {
    case sending
    case sent
    case failed
}

// MARK: - View model

@MainActor
final class BolajonChatViewModel: ObservableObject {
    /// Chronological (oldest first) for top-to-bottom rendering.
    @Published private(set) var messages: [OilaChatMessage] = []
    @Published var draft: String = "" {
        didSet {
            // `SendMessageDto.text` is capped at 4000 characters. Clamp here — a paste that blows
            // past the cap used to reach the server and come back as a generic failure, with the
            // child's message already gone from the composer.
            guard draft.count > Self.maxMessageLength else { return }
            draft = String(draft.prefix(Self.maxMessageLength))
            errorMessage = L10n.tr("chat2.too_long", Self.maxMessageLength)
        }
    }
    @Published private(set) var isConnected = false
    /// Number of sends currently in flight. Published (rather than a plain Bool) so several
    /// optimistic sends can overlap without one finishing early and clearing the other's state.
    @Published private(set) var inFlightSendCount = 0
    @Published private(set) var isPreparingImage = false
    @Published private(set) var isLoading = false
    @Published private(set) var pendingImage: PendingChatImage?
    @Published var errorMessage: String?
    /// The id of the first unread inbound message — the "unread" divider renders just above it.
    @Published private(set) var unreadBoundaryID: String?
    /// Ids of local echoes still awaiting their server acknowledgement.
    @Published private(set) var sendingLocalIDs: Set<String> = []
    /// Ids of local echoes whose send failed — these keep their bubble and offer a retry.
    @Published private(set) var failedLocalIDs: Set<String> = []
    /// True while an older page of history is in flight, so the top loader can't fire twice.
    @Published private(set) var isLoadingOlder = false
    /// Whether there is (probably) older history left above what is loaded — drives the top loader.
    @Published private(set) var canLoadOlder = false

    /// Signed-URL cache + local photo previews for this screen. Not `@Published`: views observe
    /// it directly so a single attachment finishing loading doesn't rebuild the whole thread.
    let attachments: ChatAttachmentStore

    private let chat: OilaChatServicing
    private let socket: DeviceChatWebSocketService
    private var loadedOnce = false
    /// Pending post-auth-expiry reconnect, cancelled when the screen goes away.
    /// Refetch scheduled when the socket comes back up. See `onConnectedChange`.
    private var resyncTask: Task<Void, Never>?
    /// Explicit keyset cursor from the last page, when the response carried one.
    private var historyCursor: String?
    /// What each unacknowledged echo was made of, so a failed send can be retried verbatim
    /// instead of asking the child to type (or pick the photo) again.
    private var outbox: [String: OutgoingChatDraft] = [:]

    /// One message the child sent that the server hasn't acknowledged yet.
    private struct OutgoingChatDraft {
        let localID: String
        let text: String?
        let imageData: Data?
    }

    init(
        chat: OilaChatServicing = OilaDeviceClient.shared,
        socket: DeviceChatWebSocketService? = nil
    ) {
        // The socket is @MainActor-isolated, so it can't be a default-argument value (those are
        // evaluated in a nonisolated context) — build it here, inside this @MainActor init.
        let socket = socket ?? DeviceChatWebSocketService()
        self.chat = chat
        self.socket = socket
        self.attachments = ChatAttachmentStore(chat: chat)
        socket.onConnectedChange = { [weak self] connected in
            guard let self else { return }
            let wasConnected = self.isConnected
            self.isConnected = connected
            // Resync on every (re)connect, not once per view-model. History was fetched exactly
            // once (`loadedOnce`) and nothing refetched afterwards, so any message the parent sent
            // while the socket was down — up to the backoff cap, or a whole backgrounded stretch —
            // never entered an already-open thread. It stayed missing until the child popped and
            // re-pushed the screen. `load()` merges rather than replaces, so this is safe to repeat
            // and cannot drop an in-flight local echo.
            guard connected, !wasConnected, self.loadedOnce else { return }
            self.resyncTask?.cancel()
            self.resyncTask = Task { [weak self] in await self?.load() }
        }
        socket.onMessage = { [weak self] message in self?.ingest(message) }
        socket.onEvent = { [weak self] event, payload in self?.applyEvent(event, payload) }
        socket.onAuthExpired = { [weak self] in
            guard let self else { return }
            self.isConnected = false
            // Deliberately NO retry here. This used to schedule a fixed 5s reconnect, which
            // overrode the service's exponential backoff entirely — and because a fast transport
            // failure was misread as auth expiry, that made an offline child retry every 5s
            // indefinitely with the radio awake. A server-side unpair produced the same loop:
            // ~720 rejected upgrades an hour that could never succeed, since no code path on a
            // device can obtain a new token.
            //
            // The service owns retry timing and already re-reads the token in `makeURL()` on every
            // attempt, so a refresh that lands meanwhile is picked up without any help from here.
        }
    }

    var isSending: Bool { inFlightSendCount > 0 }
    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
    }

    func appear() async {
        socket.connect()
        if !loadedOnce { await load() }
    }

    func disappear() {
        resyncTask?.cancel()
        resyncTask = nil
        socket.disconnect()
    }

    func load() async {
#if DEBUG
        if messages.isEmpty && AppRuntime.hasDebugRoute {
            messages = Self.sampleMessages
            unreadBoundaryID = "s5"
            isConnected = true
            isLoading = false
            return
        }
#endif
        isLoading = messages.isEmpty
        do {
            let page = try await chat.fetchChatMessages(limit: Self.pageSize, before: nil)
            // Merge rather than replace: a local echo whose send is still in flight (or has
            // failed) is not in the server's page, and dropping it would make the child's message
            // vanish mid-send. Keeping the rest of `messages` matters too now that older pages can
            // be loaded — replacing wholesale would throw that history away on every resync.
            // `sortedDedup` keeps the first occurrence, so the fresh server copy still wins.
            messages = sortedDedup(page.messages + messages)
            historyCursor = page.nextCursor
            canLoadOlder = Self.hasMoreHistory(after: page)
            errorMessage = nil
            loadedOnce = true
            await refreshUnreadBoundaryAndMarkRead()
        } catch {
            errorMessage = NetworkError.userMessage(for: error)
        }
        isLoading = false
    }

    /// One HTTP catch-up for a thread that is already open. The socket is suspended while the app
    /// is backgrounded and a chat push arrives without one at all, so anything the parent sent in
    /// the meantime is only reachable over HTTP — this is the single resync the team agreed on.
    /// Socket retry timing is deliberately left to the service, exactly as `onAuthExpired` notes.
    /// `load()` merges and re-flushes the read watermark, so this is safe to repeat.
    func resync() async {
        guard loadedOnce else { return }
        // Any signed attachment URL that expired meanwhile is re-minted here rather than left to
        // fail inside `AsyncImage`.
        attachments.refreshExpired()
        resyncTask?.cancel()
        let task: Task<Void, Never> = Task { [weak self] in await self?.load() }
        resyncTask = task
        await task.value
    }

    /// Pulls the next OLDER page. History is keyset-paginated newest-first (`before` + the page's
    /// cursor), but only the newest page was ever fetched — so a thread longer than one page was
    /// silently truncated at its top with no way to reach the rest.
    func loadOlder() async {
        guard loadedOnce, !isLoadingOlder, canLoadOlder, let cursor = olderPageCursor() else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await chat.fetchChatMessages(limit: Self.pageSize, before: cursor)
            messages = sortedDedup(page.messages + messages)
            historyCursor = page.nextCursor
            canLoadOlder = Self.hasMoreHistory(after: page)
            errorMessage = nil
        } catch {
            // Stop the top loader re-firing against a failing endpoint; entering the thread again
            // (or the next resync) re-arms it from a fresh newest page.
            canLoadOlder = false
            errorMessage = NetworkError.userMessage(for: error)
        }
    }

    func dismissError() { errorMessage = nil }

    // MARK: Composing

    /// Reads the picked photo, downscales/compresses it, and parks it in the composer. The picker
    /// is out-of-process (`PhotosPicker`), so this needs no photo-library permission and never
    /// touches the camera.
    func attachImage(from item: PhotosPickerItem) async {
        guard !isPreparingImage else { return }
        isPreparingImage = true
        defer { isPreparingImage = false }
        do {
            guard let original = try await item.loadTransferable(type: Data.self) else {
                errorMessage = L10n.tr("chat2.attach_failed")
                return
            }
            let prepared = await Task.detached(priority: .userInitiated) {
                ChatImagePreparer.jpegData(from: original)
            }.value
            guard let prepared, let preview = UIImage(data: prepared) else {
                errorMessage = L10n.tr("chat2.attach_failed")
                return
            }
            pendingImage = PendingChatImage(data: prepared, preview: preview)
            errorMessage = nil
        } catch {
            errorMessage = L10n.tr("chat2.attach_failed")
        }
    }

    func clearPendingImage() { pendingImage = nil }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil else { return }
        // The composer is emptied up front and an echo takes the message's place, so the child
        // sees the bubble immediately instead of after the whole round trip.
        draft = ""
        pendingImage = nil

        let outgoing = OutgoingChatDraft(
            localID: Self.localIDPrefix + UUID().uuidString,
            text: text.isEmpty ? nil : text,
            imageData: image?.data
        )
        outbox[outgoing.localID] = outgoing
        if let preview = image?.preview { attachments.setPreview(preview, for: outgoing.localID) }
        appendEcho(for: outgoing)
        await deliver(outgoing)
    }

    /// Re-sends a failed echo. Keyed by the echo's own id, so it stays matched to the bubble the
    /// child tapped even if other messages arrived meanwhile.
    func retrySend(_ localID: String) async {
        guard let outgoing = outbox[localID], !sendingLocalIDs.contains(localID) else { return }
        failedLocalIDs.remove(localID)
        sendingLocalIDs.insert(localID)
        errorMessage = nil
        await deliver(outgoing)
    }

    func deliveryState(for messageID: String) -> ChatDeliveryState {
        if failedLocalIDs.contains(messageID) { return .failed }
        if sendingLocalIDs.contains(messageID) { return .sending }
        return .sent
    }

    // MARK: Internals

    private func appendEcho(for outgoing: OutgoingChatDraft) {
        sendingLocalIDs.insert(outgoing.localID)
        failedLocalIDs.remove(outgoing.localID)
        // Goes through `ingest` so it reuses the existing dedup-by-id + chronological sort. The
        // id is locally minted and prefixed, so it can never collide with a server id.
        ingest(
            OilaChatMessage(
                id: outgoing.localID,
                text: outgoing.text,
                sender: .child,
                createdAt: Date(),
                hasImage: outgoing.imageData != nil,
                readByPeer: false,
                raw: [:]
            )
        )
    }

    private func deliver(_ outgoing: OutgoingChatDraft) async {
        inFlightSendCount += 1
        defer { inFlightSendCount -= 1 }
        do {
            let sent = try await chat.sendChatMessage(
                text: outgoing.text,
                imageData: outgoing.imageData,
                imageMimeType: outgoing.imageData == nil ? nil : "image/jpeg"
            )
            let acknowledged = Self.reconciled(sent, echo: messages.first { $0.id == outgoing.localID })
            // Hand the already-decoded photo to the real message before the echo goes away, so
            // the bubble keeps rendering without a pointless attachment round trip.
            attachments.movePreview(from: outgoing.localID, to: acknowledged.id)
            removeEcho(outgoing.localID)
            ingest(acknowledged)
            unreadBoundaryID = nil
            errorMessage = nil
        } catch {
            // Keep the bubble: it carries the retry affordance, and the text/photo lives on in
            // `outbox` so nothing the child wrote is lost.
            sendingLocalIDs.remove(outgoing.localID)
            failedLocalIDs.insert(outgoing.localID)
            errorMessage = NetworkError.userMessage(for: error)
        }
    }

    /// Fills the gaps in the message the send endpoint returns before it replaces the local echo.
    /// That 2xx schema is untyped (`{}` in the spec) and real responses routinely omit `sender`
    /// and `createdAt` — which drops the child's own bubble on the PARENT's side of the thread and
    /// sorts it to `.distantPast`, i.e. jumps it to the very top of the history. For a message we
    /// just sent ourselves those values are known, so fill them in rather than trust the gap.
    private static func reconciled(_ sent: OilaChatMessage, echo: OilaChatMessage?) -> OilaChatMessage {
        let sender: OilaChatMessage.Sender = (sent.sender == .unknown) ? .child : sent.sender
        let createdAt = sent.createdAt ?? echo?.createdAt ?? Date()
        let hasImage = sent.hasImage || (echo?.hasImage ?? false)
        guard sender != sent.sender || createdAt != sent.createdAt || hasImage != sent.hasImage else {
            return sent
        }
        return OilaChatMessage(
            id: sent.id,
            text: sent.text ?? echo?.text,
            sender: sender,
            createdAt: createdAt,
            hasImage: hasImage,
            readByPeer: sent.readByPeer,
            raw: sent.raw,
            systemKind: sent.systemKind,
            systemData: sent.systemData
        )
    }

    private func removeEcho(_ localID: String) {
        sendingLocalIDs.remove(localID)
        failedLocalIDs.remove(localID)
        outbox[localID] = nil
        attachments.clearPreview(for: localID)
        messages.removeAll { $0.id == localID }
    }

    /// The `before` value for the next older page. The endpoint documents it as "load messages
    /// older than this message id (keyset cursor)", so when a response carries no explicit cursor
    /// — a bare JSON array has nowhere to put paging meta — the oldest server message already
    /// held is itself a valid cursor. Local echoes are skipped: they have no server identity.
    private func olderPageCursor() -> String? {
        if let historyCursor = historyCursor?.trimmedNonEmpty { return historyCursor }
        return messages.first { !$0.id.hasPrefix(Self.localIDPrefix) }?.id
    }

    /// A page shorter than the one that was asked for means the head of the thread was reached;
    /// an explicit cursor means there is definitely more. Nothing else can be known, since the
    /// response schema is undocumented.
    private static func hasMoreHistory(after page: OilaChatPage) -> Bool {
        page.nextCursor?.trimmedNonEmpty != nil || page.messages.count >= pageSize
    }

    private func ingest(_ message: OilaChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message           // e.g. a read-receipt update for a sent message
            return
        }
        messages.append(message)
        messages.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        if message.sender == .parent {
            // Arrived while the thread is open → immediately read.
            Task { [weak self] in try? await self?.chat.markChatRead(lastMessageId: message.id) }
        }
    }

    /// Realtime read receipt (`chat:read`): the parent read our messages — flip ✓✓ on our own sent
    /// messages up to `readAt`. Ignore an echo of the child's own reads (reader == "child").
    private func applyEvent(_ event: String, _ payload: [String: Any]) {
        guard Self.isReadReceiptEvent(event) else { return }
        if (payload["reader"] as? String)?.lowercased() == "child" { return }
        // Falling back to "now" is only correct for an event that genuinely carries no timestamp:
        // the peer just read the thread, so everything already sent counts as read. Several key
        // spellings are tried for the same reason `OilaDeviceClient` does it — the chat payload
        // schema is undocumented, and landing on this fallback marks the WHOLE thread read.
        let readAt = Self.parseISO(payload["readAt"])
            ?? Self.parseISO(payload["read_at"])
            ?? Self.parseISO(payload["readAtUtc"])
            ?? Self.parseISO(payload["timestamp"])
            ?? Self.parseISO(payload["ts"])
            ?? Date()
        messages = messages.map { message in
            // An unacknowledged echo has no server identity yet, so the parent cannot have read
            // it — leave its sending/failed presentation alone.
            let isEcho = sendingLocalIDs.contains(message.id) || failedLocalIDs.contains(message.id)
            return (message.sender == .child && !isEcho && !message.readByPeer
                    && (message.createdAt ?? .distantPast) <= readAt)
                ? message.markedReadByPeer() : message
        }
    }

    /// True only for a genuine read-receipt event. A plain `contains("read")` also fires on
    /// "unread" and "thread" — so `chat.unread_count` or `thread.updated` reached the `?? Date()`
    /// fallback above and marked the entire thread as read by the parent. Matching "read" as a
    /// whole separator-delimited token keeps `chat:read` / `chat.read` / `message_read` working
    /// while excluding both impostors.
    private static func isReadReceiptEvent(_ event: String) -> Bool {
        event.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { $0 == "read" }
    }

    // The backend emits fractional-second ISO timestamps ("2026-07-26T09:15:02.418Z"), and a
    // default-configured ISO8601DateFormatter rejects those outright — which used to make every
    // `readAt` parse fail and fall through to "now", marking the whole thread read. Mirror
    // `OilaDeviceClient`'s own date helper: fractional-seconds first, then a plain formatter for
    // payloads that omit the milliseconds. These are two separate immutable instances on purpose —
    // toggling `formatOptions` on one shared formatter between calls would be a data race.
    private static let isoParserFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoParser = ISO8601DateFormatter()

    /// Prefix that marks a locally-minted echo id; server ids never carry it.
    private static let localIDPrefix = "local-echo-"

    /// Messages per history request (the endpoint caps `limit` at 100).
    private static let pageSize = 40

    /// `SendMessageDto.text` is declared 1..4000 in the spec.
    private static let maxMessageLength = 4000

    private static func parseISO(_ any: Any?) -> Date? {
        guard let string = (any as? String)?.trimmedNonEmpty else { return nil }
        return isoParserFractional.date(from: string) ?? isoParser.date(from: string)
    }

    private func refreshUnreadBoundaryAndMarkRead() async {
        let count = (try? await chat.fetchChatUnreadCount()) ?? 0
        if count > 0 {
            let inbound = messages.filter { $0.sender == .parent }
            unreadBoundaryID = inbound.suffix(count).first?.id
        } else {
            unreadBoundaryID = nil
        }
        if let newest = messages.last(where: { !sendingLocalIDs.contains($0.id) && !failedLocalIDs.contains($0.id) })?.id {
            try? await chat.markChatRead(lastMessageId: newest)
        }
    }

    private func sortedDedup(_ items: [OilaChatMessage]) -> [OilaChatMessage] {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        return unique.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

#if DEBUG
    /// Sample thread for the `chat2` debug route (no live session/token in debug).
    static var sampleMessages: [OilaChatMessage] {
        let now = Date()
        func m(_ id: String, _ text: String, _ sender: OilaChatMessage.Sender,
               _ secondsAgo: TimeInterval, read: Bool = false) -> OilaChatMessage {
            OilaChatMessage(id: id, text: text, sender: sender,
                            createdAt: now.addingTimeInterval(-secondsAgo),
                            hasImage: false, readByPeer: read, raw: [:])
        }
        return [
            m("s1", "Salom, maktabdan chiqdingmi?", .parent, 3600),
            m("s2", "Ha, hozir avtobusdaman", .child, 3500, read: true),
            m("s3", "Uyga qachon yetib kelasan?", .parent, 3400),
            m("s4", "20 daqiqada yetib boraman", .child, 3300, read: true),
            m("s5", "Yaxshi, ehtiyot bo'l 👍", .parent, 300),
            m("s6", "Xona vazifangni unutma", .parent, 180)
        ]
    }
#endif
}

// MARK: - Screen

struct BolajonChatView: View {
    @StateObject private var viewModel = BolajonChatViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composerFocused: Bool
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var enlargedImage: ChatImagePreviewItem?
    /// See `olderHistoryLoader`: the paging row is on screen for the first frame of every open,
    /// and that appearance must not trigger a fetch.
    @State private var didSkipInitialLoaderAppearance = false

    var body: some View {
        ZStack {
            AppColors.screenBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                messageList
                if let error = viewModel.errorMessage {
                    ChatErrorStrip(message: error) { viewModel.dismissError() }
                }
                composer
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(L10n.tr("chat2.peer"))
                        .font(AppTypography.bodyStrong(16))
                        .foregroundStyle(AppColors.inkPrimary)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(viewModel.isConnected ? AppColors.successGreen : AppColors.inkTertiary)
                            .frame(width: 6, height: 6)
                        Text(L10n.tr(viewModel.isConnected ? "chat2.online" : "chat2.connecting"))
                            .font(AppTypography.caption(12))
                            .foregroundStyle(viewModel.isConnected ? AppColors.successGreen : AppColors.inkTertiary)
                    }
                }
            }
        }
        .task { await viewModel.appear() }
        .onDisappear { viewModel.disappear() }
        .onChange(of: scenePhase) { phase in
            // Back to the foreground: the socket was suspended while backgrounded, so anything the
            // parent sent meanwhile never reached an open thread. One HTTP resync (which also
            // re-flushes the read watermark), plus a re-mint of any signed attachment URL that
            // expired in the background.
            guard phase == .active else { return }
            Task { await viewModel.resync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshChat)) { notification in
            // A chat push is the one signal that survives a suspended socket, so an open thread
            // pulls the message in over HTTP rather than waiting for the socket to come back.
            guard Self.pushMatchesDevice(notification) else { return }
            Task { await viewModel.resync() }
        }
        .onChange(of: pickedPhoto) { item in
            guard let item else { return }
            Task {
                await viewModel.attachImage(from: item)
                // Reset so picking the SAME photo again still fires onChange.
                pickedPhoto = nil
            }
        }
        .fullScreenCover(item: $enlargedImage) { item in
            ChatImageViewer(source: item.source) { enlargedImage = nil }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if viewModel.messages.isEmpty, !viewModel.isLoading {
                        emptyState
                    }
                    if viewModel.canLoadOlder {
                        olderHistoryLoader(proxy)
                    }
                    ForEach(viewModel.messages) { message in
                        if message.id == viewModel.unreadBoundaryID {
                            UnreadDivider().id("unread-divider")
                        }
                        if message.sender == .system {
                            ChatSystemNotice(message: message).id(message.id)
                        } else {
                            ChatBubble(
                                message: message,
                                deliveryState: viewModel.deliveryState(for: message.id),
                                attachments: viewModel.attachments,
                                onOpenImage: { source in
                                    enlargedImage = ChatImagePreviewItem(id: message.id, source: source)
                                },
                                onRetry: { Task { await viewModel.retrySend(message.id) } }
                            )
                            .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // Keyed on the NEWEST message rather than the count: loading an older page also
            // changes the count, and jumping to the bottom would yank the thread out from under
            // the child the moment their history finished loading.
            .onChange(of: viewModel.messages.last?.id) { _ in scrollToBottom(proxy) }
            .onChange(of: composerFocused) { focused in if focused { scrollToBottom(proxy) } }
            .task { scrollToBottom(proxy, animated: false) }
        }
    }

    /// Top-of-thread trigger for keyset paging: it only exists while older history is left, and
    /// scrolling it into view fetches the next page.
    ///
    /// A `ScrollView` lays out from the top, so this row is on screen for the first frame of every
    /// open — before `scrollToBottom` runs. Fetching on that first appearance would pull an
    /// unrequested page and re-anchor the child away from the newest message, so the first
    /// appearance is deliberately skipped and only a genuine scroll back up pages.
    private func olderHistoryLoader(_ proxy: ScrollViewProxy) -> some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(AppColors.inkTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .onAppear {
                guard didSkipInitialLoaderAppearance else {
                    didSkipInitialLoaderAppearance = true
                    return
                }
                let anchor = viewModel.messages.first?.id
                Task {
                    await viewModel.loadOlder()
                    // Prepending changes the content height, so re-anchor on the row that used to
                    // be at the top — otherwise the thread visibly jumps.
                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                }
            }
    }

    /// Only act on a chat push addressed to THIS device (a payload without a DSN is accepted,
    /// matching `RootView.shouldHandlePush`). `persistedDSN` never mints an identity just by
    /// being asked, and reading it here keeps the screen usable from the standalone debug route,
    /// which has no `SessionStore` in its environment.
    private static func pushMatchesDevice(_ notification: Notification) -> Bool {
        guard let currentDSN = OilaDeviceIdentity.persistedDSN() else { return false }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if let pending = viewModel.pendingImage {
                pendingImageStrip(pending)
            }
            HStack(spacing: 10) {
                photoButton
                TextField(L10n.tr("chat2.placeholder"), text: $viewModel.draft, axis: .vertical)
                    .font(AppTypography.bodyText(15))
                    .foregroundStyle(AppColors.inkPrimary)
                    .lineLimit(1...4)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(AppColors.cardWhite))
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(send)

                Button(action: send) {
                    ZStack {
                        Circle()
                            .fill(viewModel.canSend ? AppColors.ctaPurple : AppColors.ctaPurple.opacity(0.4))
                            .frame(width: 46, height: 46)
                        if viewModel.isSending {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(AppColors.inverseTextPrimary)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AppColors.inverseTextPrimary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend)
                .accessibilityLabel(Text(L10n.tr("chat2.send")))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.screenBackground)
    }

    /// Out-of-process photo picker: it needs no `NSPhotoLibraryUsageDescription` and never opens
    /// the camera, which is what keeps this composer shippable without extra Info.plist strings.
    private var photoButton: some View {
        // Read the view-model state HERE rather than inside the label builder: the picker's label
        // closure is not main-actor-isolated, so touching `viewModel` from inside it is a
        // concurrency violation (a warning today, an error under the Swift 6 language mode).
        let preparing = viewModel.isPreparingImage
        let busy = preparing || viewModel.isSending
        return PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
            ZStack {
                Circle().fill(AppColors.cardWhite).frame(width: 46, height: 46)
                if preparing {
                    ProgressView().progressViewStyle(.circular).tint(AppColors.ctaPurple)
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.ctaPurple)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .accessibilityLabel(Text(L10n.tr("chat2.attach")))
    }

    private func pendingImageStrip(_ pending: PendingChatImage) -> some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: pending.preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button { viewModel.clearPendingImage() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(AppColors.inverseTextPrimary, AppColors.inkPrimary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel(Text(L10n.tr("chat2.attachment.remove")))
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(L10n.tr("chat2.empty"))
                .font(AppTypography.bodyStrong(15))
                .foregroundStyle(AppColors.inkSecondary)
            Text(L10n.tr("chat2.empty_hint"))
                .font(AppTypography.bodyText(13))
                .foregroundStyle(AppColors.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func send() {
        Task { await viewModel.send() }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !viewModel.messages.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private static let bottomAnchor = "chat-bottom-anchor"
}

// MARK: - Error strip

/// Compact failure line above the composer. Load and send errors used to be written to
/// `errorMessage` and then rendered nowhere, so a failed history fetch looked exactly like an
/// empty thread.
private struct ChatErrorStrip: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.sosCoral)
            Text(message)
                .font(AppTypography.caption(12))
                .foregroundStyle(AppColors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppColors.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("chat2.error.dismiss")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppColors.sosCoral.opacity(0.12))
        )
        .padding(.horizontal, 14)
    }
}

// MARK: - Bubble

private struct ChatBubble: View {
    let message: OilaChatMessage
    let deliveryState: ChatDeliveryState
    @ObservedObject var attachments: ChatAttachmentStore
    let onOpenImage: (ChatImageSource) -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack {
            if message.isFromChild { Spacer(minLength: 48) }
            VStack(alignment: message.isFromChild ? .trailing : .leading, spacing: 6) {
                content
                metaRow
                if message.isFromChild, deliveryState == .failed { retryRow }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleShape)
            if !message.isFromChild { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder private var content: some View {
        if message.hasImage {
            ChatImageAttachment(
                messageID: message.id,
                attachments: attachments,
                isUploading: deliveryState == .sending,
                onOpen: onOpenImage
            )
        }
        if let text = message.text, !text.isEmpty {
            Text(text)
                .font(AppTypography.bodyText(15))
                .foregroundStyle(message.isFromChild ? AppColors.inverseTextPrimary : AppColors.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 5) {
            if let time = Self.timeString(message.createdAt) {
                Text(time)
                    .font(AppTypography.caption(11))
                    .foregroundStyle(message.isFromChild ? AppColors.inverseTextSecondary : AppColors.inkTertiary)
            }
            if message.isFromChild {
                switch deliveryState {
                case .sending:
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppColors.inverseTextSecondary)
                        .accessibilityLabel(Text(L10n.tr("chat2.status.sending")))
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppColors.inverseTextPrimary)
                case .sent:
                    Text(message.readByPeer ? "✓✓" : "✓")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppColors.inverseTextSecondary)
                }
            }
        }
    }

    private var retryRow: some View {
        Button(action: onRetry) {
            HStack(spacing: 5) {
                Text(L10n.tr("chat2.status.failed"))
                Text("·")
                Text(L10n.tr("chat2.status.retry")).underline()
            }
            .font(AppTypography.caption(11))
            .foregroundStyle(AppColors.inverseTextPrimary)
        }
        .buttonStyle(.plain)
    }

    private var bubbleShape: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(message.isFromChild ? AppColors.ctaPurple : AppColors.cardWhite)
            .shadow(color: message.isFromChild ? .clear : BolajonMetrics.cardShadow,
                    radius: 6, x: 0, y: 3)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // `.short` rather than a hardcoded "HH:mm": a 24-hour clock was being shown to every reader
        // regardless of their region setting, so a family on a 12-hour clock read 19:05 for 7:05 PM
        // in the one screen that is a conversation. `autoupdatingCurrent` keeps it right if the
        // region changes while the app is alive.
        f.locale = .autoupdatingCurrent
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static func timeString(_ date: Date?) -> String? {
        guard let date else { return nil }
        return formatter.string(from: date)
    }
}

// MARK: - Image attachment

/// The image inside a bubble. The signed URL is fetched lazily on first appearance (never
/// persisted — see `ChatAttachmentStore`), with an explicit loading state and a tap-to-retry
/// failure state, since an expired URL is a normal outcome rather than an exception here.
private struct ChatImageAttachment: View {
    let messageID: String
    @ObservedObject var attachments: ChatAttachmentStore
    let isUploading: Bool
    let onOpen: (ChatImageSource) -> Void

    private static let width: CGFloat = 216
    private static let placeholderHeight: CGFloat = 162
    private static let maxHeight: CGFloat = 260

    var body: some View {
        Group {
            if let preview = attachments.preview(for: messageID) {
                framed(Image(uiImage: preview))
                    .overlay { if isUploading { uploadOverlay } }
                    .contentShape(Rectangle())
                    .onTapGesture { if !isUploading { onOpen(.local(preview)) } }
                    .accessibilityLabel(Text(L10n.tr(isUploading ? "chat2.status.sending" : "chat2.image.open")))
            } else if let state = attachments.state(for: messageID) {
                switch state {
                case .ready(let url):
                    remote(url)
                case .failed:
                    failedPlaceholder
                        .onTapGesture { attachments.retry(messageID) }
                case .loading:
                    loadingPlaceholder
                }
            } else {
                loadingPlaceholder
            }
        }
        // `onAppear` rather than `task`: the store is @MainActor and this closure inherits the
        // body's main-actor isolation, so no hop (and no cancellation on a LazyVStack recycle).
        .onAppear { attachments.load(messageID) }
    }

    private func remote(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                framed(image)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(.remote(url)) }
                    .accessibilityLabel(Text(L10n.tr("chat2.image.open")))
            case .failure:
                // The signed URL expires; a load failure is most often staleness, so retry means
                // "ask for a brand new URL", not "re-request the same one".
                failedPlaceholder
                    .onTapGesture { attachments.retry(messageID) }
            case .empty:
                loadingPlaceholder
            @unknown default:
                loadingPlaceholder
            }
        }
    }

    private func framed(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: Self.width, maxHeight: Self.maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var loadingPlaceholder: some View {
        placeholderSurface {
            VStack(spacing: 6) {
                ProgressView().progressViewStyle(.circular).tint(AppColors.inkTertiary)
                Text(L10n.tr("chat2.photo.loading"))
                    .font(AppTypography.caption(11))
                    .foregroundStyle(AppColors.inkTertiary)
            }
        }
    }

    private var failedPlaceholder: some View {
        placeholderSurface {
            VStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.inkSecondary)
                Text(L10n.tr("chat2.photo.failed"))
                    .font(AppTypography.caption(11))
                    .foregroundStyle(AppColors.inkSecondary)
                Text(L10n.tr("chat2.photo.retry"))
                    .font(AppTypography.caption(11))
                    .foregroundStyle(AppColors.inkTertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func placeholderSurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.chipNeutral)
            content()
        }
        .frame(width: Self.width, height: Self.placeholderHeight)
    }

    private var uploadOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.35))
            ProgressView().progressViewStyle(.circular).tint(AppColors.inverseTextPrimary)
        }
    }
}

// MARK: - Full-screen image viewer

/// Tap-to-enlarge. Double-tap toggles a 2.5× zoom and a drag pans while zoomed — enough to read a
/// photo of a homework page without pulling in a gesture API deprecated after iOS 16.
private struct ChatImageViewer: View {
    let source: ChatImageSource
    let onClose: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { onClose() }
            content
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.tr("chat2.image.close")))
                }
                Spacer()
            }
            .padding(18)
        }
    }

    @ViewBuilder private var content: some View {
        switch source {
        case .local(let image):
            zoomable(Image(uiImage: image))
        case .remote(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    zoomable(image)
                case .failure:
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(L10n.tr("chat2.photo.failed"))
                            .font(AppTypography.bodyText(14))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                default:
                    ProgressView().progressViewStyle(.circular).tint(.white)
                }
            }
        }
    }

    private func zoomable(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom)
            .offset(offset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard zoom > 1 else { return }
                        offset = CGSize(width: dragStart.width + value.translation.width,
                                        height: dragStart.height + value.translation.height)
                    }
                    .onEnded { _ in dragStart = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if zoom > 1 {
                        zoom = 1
                        offset = .zero
                    } else {
                        zoom = 2.5
                    }
                    dragStart = offset
                }
            }
    }
}

// MARK: - System notice (SOS etc.)

private struct ChatSystemNotice: View {
    let message: OilaChatMessage

    var body: some View {
        HStack(spacing: 6) {
            if message.systemKind == "sos" {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppColors.sosCoral)
            }
            Text(noticeText)
                .font(AppTypography.caption(12))
                .foregroundStyle(message.systemKind == "sos" ? AppColors.sosCoral : AppColors.inkTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(message.systemKind == "sos" ? AppColors.sosCoral.opacity(0.12) : AppColors.chipNeutral))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var noticeText: String {
        if message.systemKind == "sos" { return L10n.tr("chat2.system.sos") }
        if let text = message.text, !text.isEmpty { return text }
        return L10n.tr("chat2.system.generic")
    }
}

// MARK: - Unread divider

private struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            line
            Text(L10n.tr("chat2.unread"))
                .font(AppTypography.bodyStrong(11))
                .foregroundStyle(AppColors.ctaPurple)
                .textCase(.uppercase)
            line
        }
        .padding(.vertical, 4)
    }

    private var line: some View {
        Rectangle().fill(AppColors.ctaPurple.opacity(0.35)).frame(height: 1)
    }
}

// MARK: - Home entry card

/// The "Ota-ona bilan suhbat" card on the Home screen — its own small model so Home stays lean.
struct ChatHomeCard: View {
    /// Bumped by Home whenever the badge has to be re-synced: the app returning to the foreground,
    /// leaving the thread, or a chat push. Push isn't delivered on this build yet, so those first
    /// two are what actually keep the badge honest.
    var refreshToken: Int = 0
    let onOpen: () -> Void
    @StateObject private var model = ChatHomeCardModel()

    var body: some View {
        Button {
            // Opening the thread marks it read on the server; clear the badge straight away so it
            // can't linger behind the child while that call is in flight. Home re-syncs from
            // `refreshToken` when the thread is closed again.
            model.clearUnread()
            onOpen()
        } label: {
            InfoCard {
                HStack(spacing: 14) {
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            Circle().fill(AppColors.ctaPurple.opacity(0.14)).frame(width: 54, height: 54)
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(AppColors.ctaPurple)
                        }
                        if model.unreadCount > 0 {
                            Text(model.unreadCount > 99 ? "99+" : "\(model.unreadCount)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppColors.inverseTextPrimary)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Circle().fill(AppColors.sosCoral))
                                .offset(x: 4, y: -4)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("home2.chat.title"))
                            .font(AppTypography.heading(17))
                            .foregroundStyle(AppColors.inkPrimary)
                        Text(model.subtitle)
                            .font(AppTypography.bodyText(13))
                            .foregroundStyle(AppColors.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.inkTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        // `task(id:)` covers both cases with one call site: the first appearance, and every later
        // refresh Home asks for by changing the token.
        .task(id: refreshToken) { await model.refresh() }
    }
}

@MainActor
private final class ChatHomeCardModel: ObservableObject {
    /// What the card has to say, as a KIND rather than as finished text.
    ///
    /// `subtitle` used to be a stored string seeded with `L10n.tr(...)` in its property initializer,
    /// which snapshots the translation at the moment the model is constructed. The child can change
    /// language from Settings without the Home card being rebuilt, so the placeholder — and the
    /// "Photo" preview, which is also a translated string — stayed in the previous language until
    /// something else forced a reload. Keeping the kind and translating at read time means the text
    /// follows the language rather than the object's lifetime.
    enum Preview: Equatable {
        case none
        case text(String)
        case photo
    }

    @Published var unreadCount = 0
    @Published private(set) var preview: Preview = .none

    var subtitle: String {
        switch preview {
        case .none: return L10n.tr("home2.chat.subtitle")
        case .photo: return L10n.tr("chat2.photo")
        case .text(let text): return text
        }
    }

    private let chat: OilaChatServicing

    init(chat: OilaChatServicing = OilaDeviceClient.shared) {
        self.chat = chat
    }

    func refresh() async {
        if let count = try? await chat.fetchChatUnreadCount() { unreadCount = count }
        if let page = try? await chat.fetchChatMessages(limit: 1, before: nil),
           let last = page.messages.first {
            if let text = last.text, !text.isEmpty {
                preview = .text(text)
            } else if last.hasImage {
                preview = .photo
            }
        }
    }

    func clearUnread() { unreadCount = 0 }
}

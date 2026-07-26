import SwiftUI

// Bolajon360 Chat (parent ↔ child). Mirrors the Android child chat: peer header with an online
// dot, child bubbles trailing (purple, with sent/read ticks), parent bubbles leading (white),
// an "unread messages" divider, and a pill composer. Wired to the oila360 device chat API
// (`OilaChatServicing`) for history/send/read + `DeviceChatWebSocketService` for realtime receive.
// Gated by `AppRuntime.chatFeaturesEnabled`.

// MARK: - View model

@MainActor
final class BolajonChatViewModel: ObservableObject {
    /// Chronological (oldest first) for top-to-bottom rendering.
    @Published private(set) var messages: [OilaChatMessage] = []
    @Published var draft: String = ""
    @Published private(set) var isConnected = false
    @Published private(set) var isSending = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// The id of the first unread inbound message — the "unread" divider renders just above it.
    @Published private(set) var unreadBoundaryID: String?

    private let chat: OilaChatServicing
    private let socket: DeviceChatWebSocketService
    private var loadedOnce = false
    /// Pending post-auth-expiry reconnect, cancelled when the screen goes away.
    private var authRetryTask: Task<Void, Never>?

    init(
        chat: OilaChatServicing = OilaDeviceClient.shared,
        socket: DeviceChatWebSocketService? = nil
    ) {
        // The socket is @MainActor-isolated, so it can't be a default-argument value (those are
        // evaluated in a nonisolated context) — build it here, inside this @MainActor init.
        let socket = socket ?? DeviceChatWebSocketService()
        self.chat = chat
        self.socket = socket
        socket.onConnectedChange = { [weak self] connected in self?.isConnected = connected }
        socket.onMessage = { [weak self] message in self?.ingest(message) }
        socket.onEvent = { [weak self] event, payload in self?.applyEvent(event, payload) }
        socket.onAuthExpired = { [weak self] in
            guard let self else { return }
            self.isConnected = false
            // Transient token rejection — retry shortly; a persistent one is handled by the app's
            // own auth flow (the device re-pairs), so we don't surface an error here. The retry is
            // held so `disappear()` can cancel it: an uncancelled one reopened the socket five
            // seconds after the child had already left the screen.
            self.authRetryTask?.cancel()
            self.authRetryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.socket.connect()
            }
        }
    }

    func appear() async {
        socket.connect()
        if !loadedOnce { await load() }
    }

    func disappear() {
        authRetryTask?.cancel()
        authRetryTask = nil
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
            let page = try await chat.fetchChatMessages(limit: 40, before: nil)
            messages = sortedDedup(page.messages)   // API is newest-first; sort makes it chronological
            errorMessage = nil
            loadedOnce = true
            await refreshUnreadBoundaryAndMarkRead()
        } catch {
            errorMessage = NetworkError.userMessage(for: error)
        }
        isLoading = false
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        draft = ""
        do {
            let sent = try await chat.sendChatMessage(text: text, imageData: nil, imageMimeType: nil)
            ingest(sent)
            unreadBoundaryID = nil
        } catch {
            errorMessage = NetworkError.userMessage(for: error)
            draft = text   // restore the unsent text so the child can retry
        }
        isSending = false
    }

    // MARK: Internals

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
            (message.sender == .child && !message.readByPeer && (message.createdAt ?? .distantPast) <= readAt)
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
        if let newest = messages.last?.id {
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
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            AppColors.screenBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                messageList
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
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if viewModel.messages.isEmpty, !viewModel.isLoading {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        if message.id == viewModel.unreadBoundaryID {
                            UnreadDivider().id("unread-divider")
                        }
                        if message.sender == .system {
                            ChatSystemNotice(message: message).id(message.id)
                        } else {
                            ChatBubble(message: message).id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _ in scrollToBottom(proxy) }
            .onChange(of: composerFocused) { focused in if focused { scrollToBottom(proxy) } }
            .task { scrollToBottom(proxy, animated: false) }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
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
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.inverseTextPrimary)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(canSend ? AppColors.ctaPurple : AppColors.ctaPurple.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text(L10n.tr("chat2.send")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.screenBackground)
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

    private var canSend: Bool {
        !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isSending
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

// MARK: - Bubble

private struct ChatBubble: View {
    let message: OilaChatMessage

    var body: some View {
        HStack {
            if message.isFromChild { Spacer(minLength: 48) }
            VStack(alignment: message.isFromChild ? .trailing : .leading, spacing: 4) {
                content
                metaRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleShape)
            if !message.isFromChild { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder private var content: some View {
        if let text = message.text, !text.isEmpty {
            Text(text)
                .font(AppTypography.bodyText(15))
                .foregroundStyle(message.isFromChild ? AppColors.inverseTextPrimary : AppColors.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } else if message.hasImage {
            Label(L10n.tr("chat2.photo"), systemImage: "photo")
                .font(AppTypography.bodyText(14))
                .foregroundStyle(message.isFromChild ? AppColors.inverseTextPrimary : AppColors.inkSecondary)
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
                Text(message.readByPeer ? "✓✓" : "✓")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppColors.inverseTextSecondary)
            }
        }
    }

    private var bubbleShape: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(message.isFromChild ? AppColors.ctaPurple : AppColors.cardWhite)
            .shadow(color: message.isFromChild ? .clear : BolajonMetrics.cardShadow,
                    radius: 6, x: 0, y: 3)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func timeString(_ date: Date?) -> String? {
        guard let date else { return nil }
        return formatter.string(from: date)
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
    let onOpen: () -> Void
    @StateObject private var model = ChatHomeCardModel()

    var body: some View {
        Button(action: onOpen) {
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
        .task { await model.refresh() }
    }
}

@MainActor
private final class ChatHomeCardModel: ObservableObject {
    @Published var unreadCount = 0
    @Published var subtitle = L10n.tr("home2.chat.subtitle")

    private let chat: OilaChatServicing

    init(chat: OilaChatServicing = OilaDeviceClient.shared) {
        self.chat = chat
    }

    func refresh() async {
        if let count = try? await chat.fetchChatUnreadCount() { unreadCount = count }
        if let page = try? await chat.fetchChatMessages(limit: 1, before: nil),
           let last = page.messages.first {
            if let text = last.text, !text.isEmpty {
                subtitle = text
            } else if last.hasImage {
                subtitle = L10n.tr("chat2.photo")
            }
        }
    }
}

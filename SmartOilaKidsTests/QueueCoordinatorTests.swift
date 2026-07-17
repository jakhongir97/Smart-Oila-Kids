import Foundation
import XCTest
@testable import SmartOilaKids

@MainActor
final class QueueCoordinatorTests: XCTestCase {
    func testTaskQueueDeduplicatesByTaskID() {
        let store = TaskActionQueueStoreSpy()
        let coordinator = TaskActionQueueCoordinator(dsn: "child-1", actionQueueStore: store)

        coordinator.enqueue(taskID: 101, awardID: 1)
        coordinator.enqueue(taskID: 101, awardID: 2)

        XCTAssertEqual(coordinator.queuedActionsCount, 1)
        XCTAssertEqual(store.savedQueues.last?.map(\.taskID), [101])
    }

    func testTaskQueueKeepsRetryableFailuresQueued() async {
        let createdAt = Date(timeIntervalSince1970: 100)
        let store = TaskActionQueueStoreSpy(
            initialQueue: [QueuedTaskAction(taskID: 7, awardID: 3, createdAt: createdAt)]
        )
        let coordinator = TaskActionQueueCoordinator(dsn: "child-1", actionQueueStore: store)

        let result = await coordinator.retryQueuedActions { _ in
            throw NetworkError.server(statusCode: 503, body: "")
        }

        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.message, L10n.tr("tasks.sync_pending", 1))
        XCTAssertEqual(store.savedQueues.last?.count, 1)
        XCTAssertEqual(store.savedQueues.last?.first?.taskID, 7)
    }

    func testTaskQueueReturnsUnrecoverableFailureMessage() async {
        let store = TaskActionQueueStoreSpy(
            initialQueue: [QueuedTaskAction(taskID: 11, awardID: 4, createdAt: .init(timeIntervalSince1970: 200))]
        )
        let coordinator = TaskActionQueueCoordinator(dsn: "child-1", actionQueueStore: store)

        let result = await coordinator.retryQueuedActions { _ in
            throw NetworkError.server(statusCode: 400, body: "{\"detail\":\"Bad request\"}")
        }

        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.message, "Bad request")
        XCTAssertEqual(store.savedQueues.last?.count, 0)
    }

    func testTaskQueueShouldRetryUsesQueueDeliveryPolicy() {
        let coordinator = TaskActionQueueCoordinator(dsn: "child-1", actionQueueStore: TaskActionQueueStoreSpy())

        XCTAssertTrue(coordinator.shouldRetry(NetworkError.server(statusCode: 408, body: "")))
        XCTAssertFalse(coordinator.shouldRetry(NetworkError.server(statusCode: 404, body: "")))
    }

    func testChatOutboxRejectsEmptyPayloads() {
        let store = ChatOutboxStoreSpy()
        let coordinator = ChatOutboxCoordinator(dsn: "child-1", outboxStore: store)

        XCTAssertFalse(coordinator.enqueue(text: "   ", attachments: []))
        XCTAssertTrue(coordinator.enqueue(text: "hello", attachments: []))
        XCTAssertTrue(coordinator.enqueue(text: "", attachments: [Data([0x01])]))
        XCTAssertEqual(coordinator.queuedMessagesCount, 2)
    }

    func testChatOutboxRetriesOnlyRetryableMessages() async {
        let store = ChatOutboxStoreSpy(
            initialQueue: [
                QueuedMessage(text: "first", attachments: []),
                QueuedMessage(text: "second", attachments: [])
            ]
        )
        let coordinator = ChatOutboxCoordinator(dsn: "child-1", outboxStore: store)

        var attemptedTexts: [String] = []
        let pending = await coordinator.retryQueuedMessages { queued in
            attemptedTexts.append(queued.text)
            return queued.text == "first" ? .failedRetryable : .sent
        }

        XCTAssertEqual(attemptedTexts, ["first", "second"])
        XCTAssertEqual(pending, L10n.tr("chat.retry_pending", 1))
        XCTAssertEqual(coordinator.queuedMessagesCount, 1)
        XCTAssertEqual(store.savedQueues.last?.map(\.text), ["first"])
    }

    func testChatOutboxShouldRetryUsesQueueDeliveryPolicy() {
        let coordinator = ChatOutboxCoordinator(dsn: "child-1", outboxStore: ChatOutboxStoreSpy())

        XCTAssertTrue(coordinator.shouldRetry(URLError(.timedOut)))
        XCTAssertFalse(coordinator.shouldRetry(NetworkError.server(statusCode: 404, body: "")))
    }
}

private final class TaskActionQueueStoreSpy: TaskActionQueueStoring {
    private(set) var savedQueues: [[QueuedTaskAction]] = []
    private var queue: [QueuedTaskAction]

    init(initialQueue: [QueuedTaskAction] = []) {
        queue = initialQueue
    }

    func loadQueue(for dsn: String) -> [QueuedTaskAction] {
        queue
    }

    func saveQueue(_ queue: [QueuedTaskAction], for dsn: String) {
        self.queue = queue
        savedQueues.append(queue)
    }
}

private final class ChatOutboxStoreSpy: ChatOutboxStoring {
    private(set) var savedQueues: [[QueuedMessage]] = []
    private var queue: [QueuedMessage]

    init(initialQueue: [QueuedMessage] = []) {
        queue = initialQueue
    }

    func loadQueue(for dsn: String) -> [QueuedMessage] {
        queue
    }

    func saveQueue(_ queue: [QueuedMessage], for dsn: String) {
        self.queue = queue
        savedQueues.append(queue)
    }
}

@MainActor
final class TaskViewModelTests: XCTestCase {
    func testLoadWithEmptyDSNFailsImmediately() async {
        let viewModel = TaskViewModel(
            dsn: "",
            service: TaskServiceSpy(),
            cacheStore: TaskCacheStoreSpy(),
            actionQueueStore: TaskActionQueueStoreSpy()
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.phase, .failed(L10n.tr("common.dsn_missing")))
        XCTAssertTrue(viewModel.awards.isEmpty)
    }

    func testLoadUsesCachedAwardsThenRefreshesAndCachesRemoteResults() async {
        let cachedAwards = [makeAward(awardID: 1, unfinishedTaskIDs: [101])]
        let remoteAwards = [makeAward(awardID: 2, unfinishedTaskIDs: [202, 203])]
        let service = TaskServiceSpy(fetchTasksResults: [.success(remoteAwards)])
        let cacheStore = TaskCacheStoreSpy(initialAwards: ["child-1": cachedAwards])
        let viewModel = TaskViewModel(
            dsn: "child-1",
            service: service,
            cacheStore: cacheStore,
            actionQueueStore: TaskActionQueueStoreSpy()
        )

        await viewModel.load()

        XCTAssertEqual(service.fetchedDSNs, ["child-1"])
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.awards.first?.awardID, 2)
        XCTAssertEqual(viewModel.awards.first?.tasks.count, 2)
        XCTAssertEqual(cacheStore.savedSnapshots.last?.dsn, "child-1")
        XCTAssertEqual(cacheStore.savedSnapshots.last?.awards.first?.awardID, 2)
    }

    func testLoadWithCachedAwardsAndRemoteFailureKeepsLoadedPhaseAndOfflineMessage() async {
        let cachedAwards = [makeAward(awardID: 3, unfinishedTaskIDs: [301])]
        let service = TaskServiceSpy(
            fetchTasksResults: [.failure(NetworkError.server(statusCode: 500, body: ""))]
        )
        let cacheStore = TaskCacheStoreSpy(initialAwards: ["child-1": cachedAwards])
        let viewModel = TaskViewModel(
            dsn: "child-1",
            service: service,
            cacheStore: cacheStore,
            actionQueueStore: TaskActionQueueStoreSpy()
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.awards.first?.awardID, 3)
        XCTAssertEqual(viewModel.messageText, L10n.tr("tasks.offline_cached"))
    }

    func testLoadRetriesQueuedActionsAndRefreshesTasksAgain() async {
        let initialAwards = [makeAward(awardID: 4, unfinishedTaskIDs: [401])]
        let refreshedAwards = [makeAward(awardID: 4, unfinishedTaskIDs: [])]
        let service = TaskServiceSpy(
            fetchTasksResults: [.success(initialAwards), .success(refreshedAwards)],
            changeTaskStatusResult: .success(
                makeChangeTaskStatusResponse(
                    taskStatus: true,
                    awardCompleted: true,
                    completedAwardID: 4
                )
            )
        )
        let queueStore = TaskActionQueueStoreSpy(
            initialQueue: [QueuedTaskAction(taskID: 401, awardID: 4, createdAt: .init(timeIntervalSince1970: 100))]
        )
        let cacheStore = TaskCacheStoreSpy()
        let viewModel = TaskViewModel(
            dsn: "child-1",
            service: service,
            cacheStore: cacheStore,
            actionQueueStore: queueStore
        )

        await viewModel.load()

        XCTAssertEqual(service.fetchedDSNs, ["child-1", "child-1"])
        XCTAssertEqual(service.changedTaskIDs, [401])
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.messageText, L10n.tr("tasks.sync_complete"))
        XCTAssertEqual(viewModel.awards.first?.tasks.count, 0)
        XCTAssertEqual(viewModel.awards.first?.isCompleted, true)
        XCTAssertEqual(queueStore.savedQueues.last?.count, 0)
    }

    func testToggleNextTaskQueuesRetryableFailureAndAppliesOptimisticCompletion() async {
        let service = TaskServiceSpy(
            changeTaskStatusResult: .failure(NetworkError.server(statusCode: 503, body: ""))
        )
        let cacheStore = TaskCacheStoreSpy()
        let queueStore = TaskActionQueueStoreSpy()
        let viewModel = TaskViewModel(
            dsn: "child-1",
            service: service,
            cacheStore: cacheStore,
            actionQueueStore: queueStore
        )
        viewModel.phase = .loaded
        viewModel.awards = [makeAward(awardID: 5, unfinishedTaskIDs: [501])]

        await viewModel.toggleNextTask(for: 5)

        XCTAssertEqual(service.changedTaskIDs, [501])
        XCTAssertEqual(viewModel.queuedActionsCount, 1)
        XCTAssertEqual(viewModel.messageText, L10n.tr("tasks.action_queued", 1))
        XCTAssertTrue(viewModel.awards[0].tasks.allSatisfy(\.isFinished))
        XCTAssertTrue(viewModel.awards[0].isCompleted)
        XCTAssertEqual(queueStore.savedQueues.last?.map(\.taskID), [501])
        XCTAssertTrue(cacheStore.savedSnapshots.last?.awards[0].tasks.allSatisfy(\.isFinished) == true)
    }

    func testToggleNextTaskNonRetryableFailureShowsUserMessageWithoutQueueing() async {
        let failure = NetworkError.server(statusCode: 400, body: #"{"detail":"Denied"}"#)
        let service = TaskServiceSpy(changeTaskStatusResult: .failure(failure))
        let viewModel = TaskViewModel(
            dsn: "child-1",
            service: service,
            cacheStore: TaskCacheStoreSpy(),
            actionQueueStore: TaskActionQueueStoreSpy()
        )
        viewModel.phase = .loaded
        viewModel.awards = [makeAward(awardID: 6, unfinishedTaskIDs: [601])]

        await viewModel.toggleNextTask(for: 6)

        XCTAssertEqual(viewModel.queuedActionsCount, 0)
        XCTAssertEqual(viewModel.messageText, NetworkError.userMessage(for: failure))
        XCTAssertEqual(viewModel.awards[0].tasks.filter(\.isFinished).count, 0)
    }

    private func makeAward(
        awardID: Int,
        unfinishedTaskIDs: [Int],
        finishedTaskIDs: [Int] = []
    ) -> AwardsResponse {
        let unfinishedTasks = unfinishedTaskIDs.map {
            TaskItem(taskID: $0, name: "Task \($0)", isFinished: false, pointsAmount: 10)
        }
        let finishedTasks = finishedTaskIDs.map {
            TaskItem(taskID: $0, name: "Task \($0)", isFinished: true, pointsAmount: 10)
        }
        let tasks = unfinishedTasks + finishedTasks

        return AwardsResponse(
            awardID: awardID,
            name: "Award \(awardID)",
            imageURL: nil,
            neededPoints: 100,
            isCompleted: unfinishedTasks.isEmpty,
            collectedCoins: finishedTasks.count * 10,
            tasks: tasks
        )
    }
}

private final class TaskServiceSpy: TaskServicing {
    var fetchTasksResults: [Result<[AwardsResponse], Error>]
    var changeTaskStatusResult: Result<ChangeTaskStatusResponse, Error>
    private(set) var fetchedDSNs: [String] = []
    private(set) var changedTaskIDs: [Int] = []

    init(
        fetchTasksResults: [Result<[AwardsResponse], Error>] = [],
        changeTaskStatusResult: Result<ChangeTaskStatusResponse, Error> = .success(
            makeChangeTaskStatusResponse(taskStatus: true, awardCompleted: false, completedAwardID: 0)
        )
    ) {
        self.fetchTasksResults = fetchTasksResults
        self.changeTaskStatusResult = changeTaskStatusResult
    }

    func fetchTasks(dsn: String) async throws -> [AwardsResponse] {
        fetchedDSNs.append(dsn)
        if fetchTasksResults.isEmpty {
            return []
        }
        return try fetchTasksResults.removeFirst().get()
    }

    func changeTaskStatus(taskID: Int) async throws -> ChangeTaskStatusResponse {
        changedTaskIDs.append(taskID)
        return try changeTaskStatusResult.get()
    }
}

private final class TaskCacheStoreSpy: TaskCacheStoring {
    struct Snapshot {
        let dsn: String
        let awards: [AwardsResponse]
    }

    private var awardsByDSN: [String: [AwardsResponse]]
    private(set) var savedSnapshots: [Snapshot] = []
    private(set) var clearedDSNs: [String] = []

    init(initialAwards: [String: [AwardsResponse]] = [:]) {
        awardsByDSN = initialAwards
    }

    func load(for dsn: String) -> [AwardsResponse] {
        awardsByDSN[dsn] ?? []
    }

    func save(_ awards: [AwardsResponse], for dsn: String) {
        awardsByDSN[dsn] = awards
        savedSnapshots.append(Snapshot(dsn: dsn, awards: awards))
    }

    func clear(for dsn: String) {
        awardsByDSN.removeValue(forKey: dsn)
        clearedDSNs.append(dsn)
    }
}

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testPresentCachedHistoryIfNeededUsesCachedMessagesAndPersistedParentName() {
        let historyStore = ChatHistoryStoreSpy(
            historyByDSN: [
                "child-1": [
                    "2026-03-11": [
                        Datum(
                            userType: "parent",
                            text: "Hello",
                            attachments: [],
                            time: "2026-03-11T08:00:00Z"
                        )
                    ]
                ]
            ]
        )
        let parentNameStore = ChatParentNameStoreSpy(initialName: "Mom")
        let viewModel = makeChatViewModel(
            service: ChatServiceSpy(),
            parentNameStore: parentNameStore,
            historyStore: historyStore
        )

        viewModel.presentCachedHistoryIfNeeded()

        XCTAssertEqual(viewModel.phase, LoadPhase.loaded)
        XCTAssertEqual(viewModel.parentDisplayName, "Mom")
        XCTAssertEqual(viewModel.unreadParentCount, 1)
        XCTAssertEqual(viewModel.sortedKeys, ["2026-03-11"])
        XCTAssertEqual(parentNameStore.savedNames.last!, "Mom")
    }

    func testRefreshLatestLoadsRemoteHistoryUpdatesPaginationAndPersistsParentFallback() async {
        let service = ChatServiceSpy(
            fetchHistoryResults: [
                .success(
                    makeChatMessagesModelFixture(
                        groupedMessages: [
                            "2026-03-11": [
                                Datum(
                                    userType: "parent",
                                    text: "Remote hello",
                                    attachments: [],
                                    time: "2026-03-11T09:00:00Z"
                                )
                            ]
                        ],
                        currentPage: 1,
                        nextPage: 2
                    )
                ),
                .success(
                    makeChatMessagesModelFixture(
                        groupedMessages: [
                            "2026-03-10": [
                                Datum(
                                    userType: "parent",
                                    text: "Older hello",
                                    attachments: [],
                                    time: "2026-03-10T09:00:00Z"
                                )
                            ]
                        ],
                        currentPage: 2,
                        nextPage: nil
                    )
                )
            ],
            fetchParentDisplayNameResult: .success("Remote Parent")
        )
        let historyStore = ChatHistoryStoreSpy()
        let parentNameStore = ChatParentNameStoreSpy()
        let viewModel = makeChatViewModel(
            service: service,
            parentNameStore: parentNameStore,
            historyStore: historyStore
        )

        await viewModel.refreshLatest()

        XCTAssertEqual(viewModel.phase, LoadPhase.loaded)
        XCTAssertEqual(viewModel.parentDisplayName, "Remote Parent")
        XCTAssertEqual(viewModel.unreadParentCount, 1)
        XCTAssertTrue(viewModel.canLoadMore)
        XCTAssertEqual(viewModel.groupedMessages["2026-03-11"]?.count, 1)
        XCTAssertEqual(historyStore.savedSnapshots.last?.0, "child-1")
        XCTAssertEqual(parentNameStore.savedNames.last!, "Remote Parent")

        await viewModel.loadOlder()

        XCTAssertEqual(service.fetchHistoryCalls.count, 2)
        XCTAssertEqual(service.fetchHistoryCalls[0].0, "child-1")
        XCTAssertEqual(service.fetchHistoryCalls[0].1, 100)
        XCTAssertEqual(service.fetchHistoryCalls[0].2, 1)
        XCTAssertEqual(service.fetchHistoryCalls[1].0, "child-1")
        XCTAssertEqual(service.fetchHistoryCalls[1].1, 100)
        XCTAssertEqual(service.fetchHistoryCalls[1].2, 2)
        XCTAssertEqual(viewModel.sortedKeys, ["2026-03-10", "2026-03-11"])
        XCTAssertFalse(viewModel.canLoadMore)
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    func testSendSuccessClearsComposerAndAppendsOutgoingMessage() async {
        let service = ChatServiceSpy(
            sendMessageResult: .success(
                makeSocketChatFixture(
                    id: 1,
                    createdAt: "2026-03-11T10:00:00Z",
                    sendFromType: "child",
                    text: "Sent text",
                    attachments: ["https://example.com/image.jpg"]
                )
            )
        )
        let historyStore = ChatHistoryStoreSpy()
        let viewModel = makeChatViewModel(service: service, historyStore: historyStore)
        viewModel.text = "Composer text"
        viewModel.setAttachments([Data([0x01, 0x02])])

        let didSend = await viewModel.send()

        XCTAssertTrue(didSend)
        XCTAssertEqual(service.sendCalls.count, 1)
        XCTAssertEqual(service.sendCalls.first?.0, "child-1")
        XCTAssertEqual(service.sendCalls.first?.1, "Composer text")
        XCTAssertEqual(service.sendCalls.first?.2, 1)
        XCTAssertEqual(viewModel.text, "")
        XCTAssertTrue(viewModel.selectedAttachments.isEmpty)
        XCTAssertNil(viewModel.sendStatusText)
        XCTAssertEqual(viewModel.groupedMessages["2026-03-11"]?.last?.userType, "child")
        XCTAssertEqual(viewModel.groupedMessages["2026-03-11"]?.last?.text, "Sent text")
        XCTAssertEqual(historyStore.savedSnapshots.last?.1["2026-03-11"]?.count, 1)
    }

    func testSendRetryableFailureQueuesMessageAndUpdatesStatus() async {
        let service = ChatServiceSpy(
            sendMessageResult: .failure(NetworkError.server(statusCode: 503, body: ""))
        )
        let outboxStore = ChatOutboxStoreSpy()
        let viewModel = makeChatViewModel(service: service, outboxStore: outboxStore)
        viewModel.text = "Queue me"
        viewModel.setAttachments([Data([0x01])])

        let didSend = await viewModel.send()

        XCTAssertTrue(didSend)
        XCTAssertEqual(viewModel.queuedMessagesCount, 1)
        XCTAssertEqual(viewModel.sendStatusText, L10n.tr("chat.send_queued", 1))
        XCTAssertEqual(outboxStore.savedQueues.last?.map(\.text), ["Queue me"])
        XCTAssertEqual(outboxStore.savedQueues.last?.first?.attachments.count, 1)
        XCTAssertEqual(viewModel.text, "")
        XCTAssertTrue(viewModel.selectedAttachments.isEmpty)
    }

    func testRetryQueuedMessagesResendsAndClearsPendingStatus() async {
        let service = ChatServiceSpy(
            sendMessageResult: .success(
                makeSocketChatFixture(
                    id: 2,
                    createdAt: "2026-03-11T11:00:00Z",
                    sendFromType: "child",
                    text: "Queued resend",
                    attachments: []
                )
            )
        )
        let outboxStore = ChatOutboxStoreSpy(initialQueue: [QueuedMessage(text: "Queued resend", attachments: [])])
        let viewModel = makeChatViewModel(service: service, outboxStore: outboxStore)

        XCTAssertEqual(viewModel.currentDSN, "child-1")
        XCTAssertEqual(viewModel.queuedMessagesCount, 1)
        XCTAssertEqual(viewModel.sendStatusText, L10n.tr("chat.retry_pending", 1))

        await viewModel.retryQueuedMessages()

        XCTAssertEqual(service.sendCalls.count, 1)
        XCTAssertEqual(service.sendCalls.first?.0, "child-1")
        XCTAssertEqual(service.sendCalls.first?.1, "Queued resend")
        XCTAssertEqual(service.sendCalls.first?.2, 0)
        XCTAssertEqual(viewModel.queuedMessagesCount, 0)
        XCTAssertNil(viewModel.sendStatusText)
        XCTAssertEqual(viewModel.groupedMessages["2026-03-11"]?.last?.text, "Queued resend")
        XCTAssertEqual(outboxStore.savedQueues.last?.count, 0)
    }

    func testThreadActivationAndIncomingParentMessageAdvanceReadMarker() {
        let readStateStore = ChatReadStateStoreSpy()
        let viewModel = makeChatViewModel(readStateStore: readStateStore)
        viewModel.groupedMessages = [
            "2026-03-11": [
                Datum(
                    userType: "parent",
                    text: "Earlier",
                    attachments: [],
                    time: "2026-03-11T12:00:00Z"
                )
            ]
        ]

        viewModel.setThreadActive(true)

        XCTAssertEqual(readStateStore.savedTimestamps.last?.1, "2026-03-11T12:00:00Z")
        XCTAssertEqual(viewModel.unreadParentCount, 0)

        viewModel.appendIncoming(
            Datum(
                userType: "parent",
                text: "Later",
                attachments: [],
                time: "2026-03-11T13:00:00Z",
                senderName: "Parent"
            )
        )

        XCTAssertEqual(readStateStore.savedTimestamps.last?.1, "2026-03-11T13:00:00Z")
        XCTAssertEqual(viewModel.unreadParentCount, 0)
        XCTAssertEqual(viewModel.parentDisplayName, "Parent")
        XCTAssertEqual(viewModel.groupedMessages["2026-03-11"]?.count, 2)
    }

    func testLoadWithEmptyDSNFailsWithoutAttemptingRemoteWork() async {
        let service = ChatServiceSpy()
        let viewModel = makeChatViewModel(dsn: "", service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.phase, .failed(L10n.tr("common.dsn_missing")))
        XCTAssertTrue(service.fetchHistoryCalls.isEmpty)
    }

    private func makeChatViewModel(
        dsn: String = "child-1",
        service: ChatServiceSpy = ChatServiceSpy(),
        outboxStore: ChatOutboxStoreSpy = ChatOutboxStoreSpy(),
        readStateStore: ChatReadStateStoreSpy = ChatReadStateStoreSpy(),
        parentNameStore: ChatParentNameStoreSpy = ChatParentNameStoreSpy(),
        historyStore: ChatHistoryStoreSpy = ChatHistoryStoreSpy()
    ) -> ChatViewModel {
        ChatViewModel(
            dsn: dsn,
            service: service,
            webSocketService: ChatWebSocketService(),
            outboxStore: outboxStore,
            readStateStore: readStateStore,
            parentNameStore: parentNameStore,
            chatHistoryStore: historyStore
        )
    }
}

final class ChatServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testFetchChatHistoryBuildsRequestAndDecodesFlatHistoryPayload() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/messages/child-1")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("page=2"))
            XCTAssertTrue(query.contains("limit=20"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")

            let payload = #"""
            {
              "pagination": {
                "current": 2,
                "previous": 1,
                "next": null,
                "per_page": 20,
                "total_page": 2,
                "total_count": 1
              },
              "data": [
                {
                  "user_type": "parent",
                  "text": "Hello from parent",
                  "attachments": [],
                  "time": "2026-03-11T09:15:00Z",
                  "sender_name": "Parent"
                }
              ]
            }
            """#.data(using: .utf8)!

            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = ChatService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let history = try await service.fetchChatHistory(dsn: "child-1", limit: 20, page: 2)

        XCTAssertEqual(history.pagination.current, 2)
        XCTAssertEqual(history.data["2026-03-11"]?.first?.text, "Hello from parent")
        XCTAssertEqual(history.data["2026-03-11"]?.first?.senderName, "Parent")
    }

    func testSendMessageBuildsMultipartBodyAndDecodesResponse() async throws {
        let attachment = Data([0x10, 0x20, 0x30])
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/messages")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
            let bodyString = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(bodyString.contains("name=\"send_from_id\""))
            XCTAssertTrue(bodyString.contains("child-1"))
            XCTAssertTrue(bodyString.contains("name=\"user_type\""))
            XCTAssertTrue(bodyString.contains("name=\"text\""))
            XCTAssertTrue(bodyString.contains("Hello child"))
            XCTAssertTrue(bodyString.contains("filename=\"image1.jpg\""))
            XCTAssertTrue(body.range(of: attachment) != nil)

            let payload = #"""
            {
              "id": 11,
              "created_at": "2026-03-11T10:00:00Z",
              "send_to_id": "parent-1",
              "send_to_type": "parent",
              "send_from_id": "child-1",
              "send_from_type": "child",
              "text": "Hello child",
              "attachments": ["https://example.com/photo.jpg"]
            }
            """#.data(using: .utf8)!

            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = ChatService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let message = try await service.sendMessage(sendFromID: "child-1", text: "Hello child", attachments: [attachment])

        XCTAssertEqual(message.id, 11)
        XCTAssertEqual(message.text, "Hello child")
        XCTAssertEqual(message.attachments, ["https://example.com/photo.jpg"])
    }

    func testFetchParentDisplayNameReturnsNilForForbiddenResponse() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            (makeHTTPResponse(for: request.url!, statusCode: 403), #"{"detail":"Forbidden"}"#.data(using: .utf8)!)
        }

        let service = ChatService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let name = try await service.fetchParentDisplayName()

        XCTAssertNil(name)
    }

    func testFetchParentDisplayNameUsesNestedResolvedName() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/members/me")

            let payload = #"{"data":{"full_name":" Parent Nested "}}"#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = ChatService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let name = try await service.fetchParentDisplayName()

        XCTAssertEqual(name, "Parent Nested")
    }
}

final class DeviceRecordingUploadServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testCompleteRecordingBuildsMultipartBodyForSupportedAndFallbackMimeTypes() async throws {
        let fixtures: [(filename: String, mimeType: String)] = [
            ("audio.m4a", "audio/mp4"),
            ("video.mov", "video/quicktime"),
            ("archive.bin", "application/octet-stream"),
        ]

        var requestIndex = 0
        TestHTTPURLProtocol.requestHandler = { request in
            let fixture = fixtures[requestIndex]
            requestIndex += 1

            XCTAssertEqual(request.httpMethod, "PUT")
            // Migrated to oila360: PUT /api/v1/device/recordings/{id}/complete (device Bearer).
            XCTAssertEqual(request.url?.path, "/api/v1/device/recordings/recording-1/complete")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dev-bearer")

            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

            let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
            let bodyText = String(decoding: body, as: UTF8.self)

            XCTAssertTrue(bodyText.contains("name=\"file\""))
            XCTAssertTrue(bodyText.contains("filename=\"\(fixture.filename)\""))
            XCTAssertTrue(bodyText.contains("Content-Type: \(fixture.mimeType)"))
            XCTAssertTrue(bodyText.contains("--Boundary-"))

            let payload = #"{"success":true,"data":{"status":"completed","deviceDsn":"child-1","url":"https://example.com/video.mp4"}}"#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = DeviceRecordingUploadService(oila: Self.makeOilaClient())

        for fixture in fixtures {
            let fileURL = makeTemporaryRecordingFile(filename: fixture.filename)
            defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

            let response = try await service.completeRecording(recordingID: "recording-1", fileURL: fileURL)
            XCTAssertEqual(response.deviceDSN, "child-1")
            XCTAssertEqual(response.status, .completed)
        }

        XCTAssertEqual(requestIndex, fixtures.count)
    }

    func testCompleteRecordingRethrowsLastRemoteError() async {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/device/recordings/recording-fail/complete")
            return (makeHTTPResponse(for: request.url!, statusCode: 500), Data("upload failed".utf8))
        }

        let service = DeviceRecordingUploadService(oila: Self.makeOilaClient())
        let fileURL = makeTemporaryRecordingFile(filename: "failed.mp4")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        do {
            _ = try await service.completeRecording(recordingID: "recording-fail", fileURL: fileURL)
            XCTFail("Expected upload to throw")
        } catch let error as OilaAPIError {
            XCTAssertEqual(error.statusCode, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// A recording-upload service backed by an oila360 client wired to the stubbed HTTP
    /// protocol with a device Bearer token, so `completeRecording` exercises the real
    /// multipart transport without touching the network.
    private static func makeOilaClient() -> OilaDeviceClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestHTTPURLProtocol.self]
        return OilaDeviceClient(
            baseURL: URL(string: "https://api.oila360.uz/api/v1")!,
            session: URLSession(configuration: configuration),
            secureTokens: SecureTokenStoreStub(access: "dev-bearer"),
            userDefaults: UserDefaults(suiteName: "RecordingUploadTests.\(UUID().uuidString)")!
        )
    }

    func testDeleteRecordingUsesDeleteEndpointAndDecodesResponse() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/devices/recordings/recording-delete")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            return (
                makeHTTPResponse(for: request.url!, statusCode: 200),
                Data(#"{"message":"deleted"}"#.utf8)
            )
        }

        let service = DeviceRecordingUploadService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let response = try await service.deleteRecording(recordingID: "recording-delete")

        XCTAssertEqual(response, DeviceRecordingDeleteResponse(message: "deleted"))
    }

    private func makeTemporaryRecordingFile(filename: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try! Data([0x10, 0x20, 0x30, 0x40]).write(to: url)
        return url
    }
}

final class TaskServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testFetchTasksBuildsRequestAndDecodesAwardsArray() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/awards/devices/child-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")

            let payload = #"""
            [
              {
                "award_id": "10",
                "name": "Morning Routine",
                "image_url": "https://example.com/award.png",
                "needed_points": "20",
                "is_completed": false,
                "collected_coins": "5",
                "tasks": [
                  {
                    "task_id": "101",
                    "name": "Brush teeth",
                    "is_finished": false,
                    "points_amount": "10"
                  }
                ]
              }
            ]
            """#.data(using: .utf8)!

            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = TaskService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let awards = try await service.fetchTasks(dsn: "child-1")

        XCTAssertEqual(awards.count, 1)
        XCTAssertEqual(awards.first?.awardID, 10)
        XCTAssertEqual(awards.first?.tasks.first?.taskID, 101)
        XCTAssertEqual(awards.first?.tasks.first?.name, "Brush teeth")
    }

    func testFetchTasksReturnsEmptyArrayForGenericEmptyPayload() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/awards/devices/child-empty")
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data("[]".utf8))
        }

        let service = TaskService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let awards = try await service.fetchTasks(dsn: "child-empty")

        XCTAssertTrue(awards.isEmpty)
    }

    func testFetchTasksThrowsDecodingFailedForUnsupportedPayloadShape() async {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/awards/devices/child-invalid")
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data(#"{"data":[]}"#.utf8))
        }

        let service = TaskService(client: makeTestAPIClient(accessToken: "Bearer access"))

        do {
            _ = try await service.fetchTasks(dsn: "child-invalid")
            XCTFail("Expected decodingFailed")
        } catch NetworkError.decodingFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChangeTaskStatusBuildsPostRequestAndDecodesResponse() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/awards/tasks/change-status/707")

            let payload = #"""
            {
              "task_status": true,
              "award_completed": true,
              "completed_award_id": 88
            }
            """#.data(using: .utf8)!

            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = TaskService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let response = try await service.changeTaskStatus(taskID: 707)

        XCTAssertTrue(response.taskStatus)
        XCTAssertTrue(response.awardCompleted)
        XCTAssertEqual(response.completedAwardID, 88)
    }

    func testFetchPendingTasksCountSubtractsOnlyQueuedUnfinishedTasksAndNeverGoesNegative() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/awards/devices/child-pending")

            let payload = #"""
            [
              {
                "award_id": 1,
                "name": "Reward 1",
                "needed_points": 100,
                "is_completed": false,
                "collected_coins": 0,
                "tasks": [
                  { "task_id": 11, "name": "Task 11", "is_finished": false, "points_amount": 10 },
                  { "task_id": 12, "name": "Task 12", "is_finished": true, "points_amount": 10 }
                ]
              }
            ]
            """#.data(using: .utf8)!

            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let queueStore = TaskActionQueueStoreSpy(
            initialQueue: [
                QueuedTaskAction(taskID: 11, awardID: 1, createdAt: .init(timeIntervalSince1970: 10)),
                QueuedTaskAction(taskID: 12, awardID: 1, createdAt: .init(timeIntervalSince1970: 11)),
                QueuedTaskAction(taskID: 99, awardID: 2, createdAt: .init(timeIntervalSince1970: 12))
            ]
        )
        let service = TaskService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            actionQueueStore: queueStore
        )

        let pendingCount = try await service.fetchPendingTasksCount(dsn: "child-pending")

        XCTAssertEqual(pendingCount, 0)
    }
}

private final class ChatServiceSpy: ChatServicing {
    var fetchHistoryResults: [Result<ChatMessagesModel, Error>]
    var sendMessageResult: Result<WBSocketChat, Error>
    var fetchParentDisplayNameResult: Result<String?, Error>
    private(set) var fetchHistoryCalls: [(String, Int, Int)] = []
    private(set) var sendCalls: [(String, String, Int)] = []

    init(
        fetchHistoryResults: [Result<ChatMessagesModel, Error>] = [],
        sendMessageResult: Result<WBSocketChat, Error> = .failure(NetworkError.server(statusCode: 500, body: "")),
        fetchParentDisplayNameResult: Result<String?, Error> = .success(nil)
    ) {
        self.fetchHistoryResults = fetchHistoryResults
        self.sendMessageResult = sendMessageResult
        self.fetchParentDisplayNameResult = fetchParentDisplayNameResult
    }

    func fetchChatHistory(dsn: String, limit: Int, page: Int) async throws -> ChatMessagesModel {
        fetchHistoryCalls.append((dsn, limit, page))
        guard !fetchHistoryResults.isEmpty else {
            return makeChatMessagesModelFixture(groupedMessages: [:], currentPage: page, nextPage: nil)
        }
        return try fetchHistoryResults.removeFirst().get()
    }

    func sendMessage(sendFromID: String, text: String, attachments: [Data]) async throws -> WBSocketChat {
        sendCalls.append((sendFromID, text, attachments.count))
        return try sendMessageResult.get()
    }

    func fetchParentDisplayName() async throws -> String? {
        try fetchParentDisplayNameResult.get()
    }
}

private final class ChatReadStateStoreSpy: ChatReadStateStoring {
    var lastReadTimestamp: String?
    private(set) var savedTimestamps: [(String, String?)] = []

    init(lastReadTimestamp: String? = nil) {
        self.lastReadTimestamp = lastReadTimestamp
    }

    func loadLastReadTimestamp(for dsn: String) -> String? {
        lastReadTimestamp
    }

    func saveLastReadTimestamp(_ timestamp: String?, for dsn: String) {
        lastReadTimestamp = timestamp
        savedTimestamps.append((dsn, timestamp))
    }
}

private final class ChatParentNameStoreSpy: ChatParentNameStoring {
    var nameByDSN: [String: String?]
    private(set) var savedNames: [String?] = []

    init(initialName: String? = nil, nameByDSN: [String: String?] = [:]) {
        if let initialName {
            self.nameByDSN = ["child-1": initialName]
        } else {
            self.nameByDSN = nameByDSN
        }
    }

    func loadParentName(for dsn: String) -> String? {
        nameByDSN[dsn] ?? nil
    }

    func saveParentName(_ name: String?, for dsn: String) {
        nameByDSN[dsn] = name
        savedNames.append(name)
    }
}

private final class ChatHistoryStoreSpy: ChatHistoryCaching {
    var historyByDSN: [String: [String: [Datum]]]
    private(set) var savedSnapshots: [(String, [String: [Datum]])] = []
    private(set) var clearedDSNs: [String] = []

    init(historyByDSN: [String: [String: [Datum]]] = [:]) {
        self.historyByDSN = historyByDSN
    }

    func loadHistory(for dsn: String) -> [String: [Datum]] {
        historyByDSN[dsn] ?? [:]
    }

    func saveHistory(_ groupedMessages: [String: [Datum]], for dsn: String) {
        historyByDSN[dsn] = groupedMessages
        savedSnapshots.append((dsn, groupedMessages))
    }

    func clearHistory(for dsn: String) {
        historyByDSN.removeValue(forKey: dsn)
        clearedDSNs.append(dsn)
    }
}

private func makeChatMessagesModelFixture(
    groupedMessages: [String: [Datum]],
    currentPage: Int,
    nextPage: Int?
) -> ChatMessagesModel {
    var pagination: [String: Any] = [
        "current": currentPage,
        "previous": currentPage > 1 ? currentPage - 1 : NSNull(),
        "per_page": 100,
        "total_page": nextPage == nil ? currentPage : nextPage!,
        "total_count": groupedMessages.values.flatMap { $0 }.count
    ]
    pagination["next"] = nextPage ?? NSNull()

    let dataPayload = groupedMessages.mapValues { messages in
        messages.map { message in
            var item: [String: Any] = [
                "user_type": message.userType,
                "attachments": message.attachments,
                "time": message.time
            ]
            if let text = message.text {
                item["text"] = text
            }
            if let senderName = message.senderName {
                item["sender_name"] = senderName
            }
            return item
        }
    }

    let payload: [String: Any] = [
        "pagination": pagination,
        "data": dataPayload
    ]

    let data = try! JSONSerialization.data(withJSONObject: payload)
    return try! JSONDecoder().decode(ChatMessagesModel.self, from: data)
}

private func makeSocketChatFixture(
    id: Int,
    createdAt: String,
    sendFromType: String,
    text: String,
    attachments: [String]
) -> WBSocketChat {
    let payload: [String: Any] = [
        "id": id,
        "created_at": createdAt,
        "send_to_id": "parent-1",
        "send_to_type": "parent",
        "send_from_id": "child-1",
        "send_from_type": sendFromType,
        "text": text,
        "attachments": attachments
    ]

    let data = try! JSONSerialization.data(withJSONObject: payload)
    return try! JSONDecoder().decode(WBSocketChat.self, from: data)
}

private func makeChangeTaskStatusResponse(
    taskStatus: Bool,
    awardCompleted: Bool,
    completedAwardID: Int
) -> ChangeTaskStatusResponse {
    let payload: [String: Any] = [
        "task_status": taskStatus,
        "award_completed": awardCompleted,
        "completed_award_id": completedAwardID
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return try! JSONDecoder().decode(ChangeTaskStatusResponse.self, from: data)
}

final class ChatPersistenceTests: XCTestCase {
    func testChatReadStateStoreTrimsValuesAndRemovesEmptyTimestamps() {
        let suiteName = "ChatReadStateStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let dsn = "child.read.1"
        let store = ChatReadStateStore(userDefaults: userDefaults)

        store.saveLastReadTimestamp(" 2026-03-11T10:00:00Z ", for: dsn)
        XCTAssertEqual(store.loadLastReadTimestamp(for: dsn), "2026-03-11T10:00:00Z")

        store.saveLastReadTimestamp("   ", for: dsn)
        XCTAssertNil(store.loadLastReadTimestamp(for: dsn))
    }

    func testChatParentNameStoreTrimsValuesAndRemovesEmptyNames() {
        let suiteName = "ChatParentNameStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let dsn = "child.parent.1"
        let store = ChatParentNameStore(userDefaults: userDefaults)

        store.saveParentName("  Parent Name  ", for: dsn)
        XCTAssertEqual(store.loadParentName(for: dsn), "Parent Name")

        store.saveParentName("", for: dsn)
        XCTAssertNil(store.loadParentName(for: dsn))
    }

    func testChatOutboxStoreRoundTripsQueueAndRemovesFileWhenEmpty() {
        let dsn = "chat-outbox-\(UUID().uuidString)"
        let store = ChatOutboxStore()
        let queueURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("chat-outbox", isDirectory: true)
            .appendingPathComponent("\(DSNScopedStorage.fileSafeIdentifier(for: dsn)).json")

        defer { store.saveQueue([], for: dsn) }

        let queue = [
            QueuedMessage(text: "Hello", attachments: [Data([0x01, 0x02, 0x03])]),
            QueuedMessage(text: "World", attachments: [])
        ]

        store.saveQueue(queue, for: dsn)
        let loaded = store.loadQueue(for: dsn)

        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].text, "Hello")
        XCTAssertEqual(loaded[0].attachments.first, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(loaded[1].text, "World")

        store.saveQueue([], for: dsn)

        XCTAssertEqual(store.loadQueue(for: dsn).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    }

    func testChatHistoryStoreSavesLoadsTrimmedAndSortedMessages() {
        let dsn = "chat-history-\(UUID().uuidString)"
        let store = ChatHistoryStore()
        defer { store.clearHistory(for: dsn) }

        let baseDate = ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z")!
        let formatter = ISO8601DateFormatter()
        // NOTE: each field is hoisted into an explicitly-typed local. Inlining the ternaries
        // directly into the Datum(...) initializer inside this .map closure tips the Swift 6
        // type-checker into an "unable to type-check in reasonable time" failure on Xcode 26.5
        // (it type-checks fine on 26.3), which reddened the iOS Simulator Tests CI workflow.
        let messages: [Datum] = (0 ..< 405).map { index in
            let userType: String = index.isMultiple(of: 2) ? "parent" : "child"
            let attachments: [String] = index == 404 ? ["https://example.com/final.jpg"] : []
            let senderName: String? = index == 404 ? "  Parent Final  " : nil
            let time: String = formatter.string(from: baseDate.addingTimeInterval(TimeInterval(index * 60)))
            return Datum(
                userType: userType,
                text: "message-\(index)",
                attachments: attachments,
                time: time,
                senderName: senderName
            )
        }

        store.saveHistory(["2026-03-01": Array(messages.reversed())], for: dsn)
        let loaded = store.loadHistory(for: dsn)
        let dayMessages = loaded["2026-03-01"] ?? []

        XCTAssertEqual(dayMessages.count, 400)
        XCTAssertEqual(dayMessages.first?.text, "message-5")
        XCTAssertEqual(dayMessages.last?.text, "message-404")
        XCTAssertEqual(dayMessages.last?.senderName, "Parent Final")
        XCTAssertEqual(dayMessages.last?.attachments, ["https://example.com/final.jpg"])

        store.clearHistory(for: dsn)
        XCTAssertTrue(store.loadHistory(for: dsn).isEmpty)
    }
}

final class TaskPersistenceTests: XCTestCase {
    func testTaskCacheStoreSaveLoadTrimsAwardsAndTasksAndCanClear() {
        let dsn = "task-cache-\(UUID().uuidString)"
        let store = TaskCacheStore()
        defer { store.clear(for: dsn) }

        let awards = (0 ..< 101).map { awardIndex in
            AwardsResponse(
                awardID: awardIndex,
                name: "Award \(awardIndex)",
                imageURL: awardIndex.isMultiple(of: 2) ? "https://example.com/\(awardIndex).jpg" : nil,
                neededPoints: 100 + awardIndex,
                isCompleted: awardIndex.isMultiple(of: 3),
                collectedCoins: awardIndex,
                tasks: (0 ..< 55).map { taskIndex in
                    TaskItem(
                        taskID: awardIndex * 1000 + taskIndex,
                        name: "Task \(taskIndex)",
                        isFinished: taskIndex.isMultiple(of: 2),
                        pointsAmount: taskIndex + 1
                    )
                }
            )
        }

        store.save(awards, for: dsn)
        let loaded = store.load(for: dsn)

        XCTAssertEqual(loaded.count, 100)
        XCTAssertEqual(loaded.first?.tasks.count, 50)
        XCTAssertEqual(loaded.last?.awardID, 99)
        XCTAssertEqual(loaded.last?.tasks.last?.taskID, 99_049)

        store.clear(for: dsn)
        XCTAssertTrue(store.load(for: dsn).isEmpty)
    }

    func testTaskActionQueueStoreRoundTripsQueueAndRemovesFileWhenEmpty() {
        let dsn = "task-queue-\(UUID().uuidString)"
        let store = TaskActionQueueStore()
        let queueURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("task-action-queue", isDirectory: true)
            .appendingPathComponent("\(DSNScopedStorage.fileSafeIdentifier(for: dsn)).json")

        defer { store.saveQueue([], for: dsn) }

        let queue = [
            QueuedTaskAction(taskID: 1, awardID: 10, createdAt: Date(timeIntervalSince1970: 100)),
            QueuedTaskAction(taskID: 2, awardID: 20, createdAt: Date(timeIntervalSince1970: 200))
        ]

        store.saveQueue(queue, for: dsn)

        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))
        XCTAssertEqual(store.loadQueue(for: dsn), queue)

        store.saveQueue([], for: dsn)

        XCTAssertTrue(store.loadQueue(for: dsn).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    }
}

final class DeviceApplicationLockPayloadParserTests: XCTestCase {
    func testParseNestedPayloadNormalizesStatusAndApplicationIdentifiers() throws {
        let parser = DeviceApplicationLockPayloadParser()
        let data = try JSONSerialization.data(withJSONObject: [
            "data": [
                "lock_status": " TRUE ",
                "applications": [
                    " com.example.one ",
                    ["package_name": " COM.example.two "],
                    ["bundle_identifier": "com.example.THREE"],
                    ["bundleIdentifier": " com.example.four "],
                    ["identifier": " com.example.five "],
                    ["identifier": "   "],
                    42
                ]
            ]
        ])

        let event = try XCTUnwrap(parser.parse(from: data))

        XCTAssertTrue(event.lockStatus)
        XCTAssertEqual(
            event.applicationIdentifiers,
            [
                "com.example.one",
                "com.example.two",
                "com.example.three",
                "com.example.four",
                "com.example.five"
            ]
        )
    }

    func testParseSupportsNumericStatusAndDefaultsMissingApplicationsToEmpty() throws {
        let parser = DeviceApplicationLockPayloadParser()
        let data = try JSONSerialization.data(withJSONObject: [
            "value": 0
        ])

        let event = try XCTUnwrap(parser.parse(from: data))

        XCTAssertFalse(event.lockStatus)
        XCTAssertTrue(event.applicationIdentifiers.isEmpty)
    }

    func testParseReturnsNilForUnsupportedPayloads() throws {
        let parser = DeviceApplicationLockPayloadParser()
        let missingStatus = try JSONSerialization.data(withJSONObject: [
            "applications": ["com.example.one"]
        ])
        let invalidJSON = Data("not-json".utf8)

        XCTAssertNil(parser.parse(from: missingStatus))
        XCTAssertNil(parser.parse(from: invalidJSON))
    }
}

final class DeviceGlobalLockPayloadParserTests: XCTestCase {
    func testParseSupportsDirectBoolJSONAndNestedStringFlags() throws {
        let parser = DeviceGlobalLockPayloadParser()
        let direct = Data("true".utf8)
        let nested = try JSONSerialization.data(withJSONObject: [
            "data": [
                "global_application_lock": " 0 "
            ]
        ])

        XCTAssertEqual(parser.parse(from: direct), true)
        XCTAssertEqual(parser.parse(from: nested), false)
    }

    func testParseReturnsNilForUnsupportedShapes() throws {
        let parser = DeviceGlobalLockPayloadParser()
        let invalid = try JSONSerialization.data(withJSONObject: [
            "message": "missing"
        ])

        XCTAssertNil(parser.parse(from: invalid))
        XCTAssertNil(parser.parse(from: Data("null".utf8)))
    }
}

final class DeviceLockServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testFetchFullLockStatusNormalizesDSNAndDecodesPayload() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/devices/dsn/child-lock-1/full_lock_status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")

            let payload = #"""
            {
              "is_locked": "1",
              "device_local_time": "08:05:33.000",
              "schedule": {
                "start_time": "22:30:00",
                "end_time": "06:45:00",
                "is_schedule_enabled": true
              }
            }
            """#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = DeviceLockService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let status = try await service.fetchFullLockStatus(dsn: " child-lock-1 ")

        XCTAssertTrue(status.isLocked)
        XCTAssertEqual(status.normalizedLocalTime, "08:05")
        XCTAssertEqual(status.schedule?.normalizedRange, "22:30 - 06:45")
    }

    func testFetchGlobalLockStatusNormalizesDSNAndParsesNestedPayload() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/devices/dsn/child-lock-2/global_application_lock")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            let payload = try JSONSerialization.data(withJSONObject: [
                "data": [
                    "global_application_lock": " 1 "
                ]
            ])
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = DeviceLockService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let isLocked = try await service.fetchGlobalLockStatus(dsn: " child-lock-2 ")

        XCTAssertTrue(isLocked)
    }

    func testFetchGlobalLockStatusThrowsDecodingFailedForUnsupportedPayload() async {
        TestHTTPURLProtocol.requestHandler = { request in
            let payload = try JSONSerialization.data(withJSONObject: ["message": "missing lock flag"])
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = DeviceLockService(client: makeTestAPIClient(accessToken: "Bearer access"))

        do {
            _ = try await service.fetchGlobalLockStatus(dsn: "child-lock-3")
            XCTFail("Expected fetchGlobalLockStatus to fail for unsupported payload")
        } catch NetworkError.decodingFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchFullLockStatusRejectsBlankDSNWithoutSendingRequest() async {
        let service = DeviceLockService(client: makeTestAPIClient(accessToken: "Bearer access"))

        do {
            _ = try await service.fetchFullLockStatus(dsn: "   ")
            XCTFail("Expected blank DSN to fail")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(TestHTTPURLProtocol.recordedRequests.isEmpty)
    }
}

final class SOSServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testSendSOSBuildsPostRequestWithDeviceDSNQuery() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/devices/notify/member")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")

            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "device_dsn" })?.value, "child-sos-service")

            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data())
        }

        let service = SOSService(client: makeTestAPIClient(accessToken: "Bearer access"))
        try await service.sendSOS(deviceDSN: "child-sos-service")

        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.count, 1)
    }
}

final class DeviceRecordingPayloadParserTests: XCTestCase {
    func testParseUsesNormalizedEventAndNestedRecordingIdentifier() throws {
        let parser = DeviceRecordingPayloadParser()
        let data = try JSONSerialization.data(withJSONObject: [
            "event": " CAMERA ",
            "id": "ignored",
            "data": [
                "recording_id": 77.0
            ]
        ])

        let event = try XCTUnwrap(parser.parse(from: data))

        XCTAssertEqual(event.type, .camera)
        XCTAssertEqual(event.recordingID, "77")
    }

    func testParseFallsBackToTopLevelIdentifierAndRejectsIncompletePayloads() throws {
        let parser = DeviceRecordingPayloadParser()
        let direct = try JSONSerialization.data(withJSONObject: [
            "event": " display ",
            "recording_id": " rec-9 "
        ])
        let missingIdentifier = try JSONSerialization.data(withJSONObject: [
            "event": "environment"
        ])
        let unknownEvent = try JSONSerialization.data(withJSONObject: [
            "event": "other",
            "recording_id": 1
        ])

        let event = try XCTUnwrap(parser.parse(from: direct))
        XCTAssertEqual(event.type, .display)
        XCTAssertEqual(event.recordingID, "rec-9")

        XCTAssertNil(parser.parse(from: missingIdentifier))
        XCTAssertNil(parser.parse(from: unknownEvent))
    }
}

final class DeviceMediaStreamStatusPayloadParserTests: XCTestCase {
    func testParseNormalizesDirectAndNestedStreamTypeFields() throws {
        let parser = DeviceMediaStreamStatusPayloadParser()
        let direct = try JSONSerialization.data(withJSONObject: [
            "event": " stop ",
            "type": " FRONT_CAMERA "
        ])
        let nested = try JSONSerialization.data(withJSONObject: [
            "event": " start ",
            "data": [
                "stream_type": " CAMERA "
            ]
        ])

        let directEvent = try XCTUnwrap(parser.parse(from: direct))
        XCTAssertEqual(directEvent.command, .stop)
        XCTAssertEqual(directEvent.streamType, .frontCamera)

        let nestedEvent = try XCTUnwrap(parser.parse(from: nested))
        XCTAssertEqual(nestedEvent.command, .start)
        XCTAssertEqual(nestedEvent.streamType, .camera)
    }

    func testParseReturnsNilWhenCommandOrStreamTypeIsMissing() throws {
        let parser = DeviceMediaStreamStatusPayloadParser()
        let missingType = try JSONSerialization.data(withJSONObject: [
            "event": "start"
        ])
        let invalidCommand = try JSONSerialization.data(withJSONObject: [
            "event": "pause",
            "stream_type": "audio"
        ])

        XCTAssertNil(parser.parse(from: missingType))
        XCTAssertNil(parser.parse(from: invalidCommand))
    }
}

final class MemberDevicesMappingTests: XCTestCase {
    func testResponseDecodesEnvelopeAndMapperSortsDedupesAndNormalizesFallbacks() throws {
        let responseData = try JSONSerialization.data(withJSONObject: [
            "results": [
                [
                    "id": "2",
                    "device_dsn": " child-2 ",
                    "username": "  Kid Two  ",
                    "avatar_url": "https://example.com/two.png"
                ],
                [
                    "id": 1,
                    "children_device_dsn": " child-1 ",
                    "full_name": "  Kid One  ",
                    "avatar_url": "   "
                ],
                [
                    "id": 1,
                    "dsn": "duplicate-child",
                    "name": "Duplicate Kid"
                ],
                [
                    "id": 3,
                    "name": "   ",
                    "username": "   ",
                    "full_name": "   ",
                    "avatar_url": "https://example.com/three.png"
                ]
            ]
        ])

        let response = try JSONDecoder().decode(MembersDevicesResponse.self, from: responseData)
        let records = MemberDevicesMapper().mapRecords(from: response)

        XCTAssertEqual(records.map(\.id), [1, 2, 3])
        XCTAssertEqual(records.map(\.dsn), ["child-1", "child-2", nil])
        XCTAssertEqual(records.map(\.name), ["Kid One", "Kid Two", ProductFallbackText.connectedDeviceName()])
        XCTAssertNil(records[0].avatarURL)
        XCTAssertEqual(records[1].avatarURL?.absoluteString, "https://example.com/two.png")
        XCTAssertEqual(records[2].avatarURL?.absoluteString, "https://example.com/three.png")
    }

    func testResponseSupportsBareArrayAndRejectsUnsupportedShapes() throws {
        let arrayData = try JSONSerialization.data(withJSONObject: [
            [
                "id": true,
                "dsn": " child-true ",
                "name": " Bool ID Kid "
            ]
        ])
        let invalidData = Data("3".utf8)

        let response = try JSONDecoder().decode(MembersDevicesResponse.self, from: arrayData)

        XCTAssertEqual(response.devices.count, 1)
        XCTAssertEqual(response.devices.first?.id, 1)
        XCTAssertEqual(response.devices.first?.resolvedDSN, " child-true ")
        XCTAssertThrowsError(try JSONDecoder().decode(MembersDevicesResponse.self, from: invalidData))
    }
}

final class MemberDevicesServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testFetchDevicesBuildsAuthorizedRequestCachesRecordsAndFallsBackToCache() async throws {
        let suiteName = "MemberDevicesServiceFetchTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer access")
        let service = makeMemberDevicesServiceForTests(
            secureTokens: secureTokens,
            userDefaults: userDefaults
        )

        var requestCount = 0
        TestHTTPURLProtocol.requestHandler = { request in
            requestCount += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/members/me/devices")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            XCTAssertTrue((request.url?.query ?? "").contains("offset=0"))

            if requestCount == 1 {
                XCTAssertTrue((request.url?.query ?? "").contains("limit=500"))
                let payload = #"""
                {
                  "results": [
                    {
                      "id": 2,
                      "device_dsn": " child-2 ",
                      "username": " Kid Two "
                    },
                    {
                      "id": 1,
                      "dsn": " child-1 ",
                      "full_name": " Kid One ",
                      "avatar_url": "https://example.com/one.jpg"
                    },
                    {
                      "id": 1,
                      "dsn": "duplicate-child",
                      "name": "Duplicate Kid"
                    }
                  ]
                }
                """#.data(using: .utf8)!
                return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
            }

            XCTAssertTrue((request.url?.query ?? "").contains("limit=1"))
            return (makeHTTPResponse(for: request.url!, statusCode: 500), Data("server-down".utf8))
        }

        let remote = try await service.fetchDevices(limit: 999)

        XCTAssertEqual(remote.map(\.id), [1, 2])
        XCTAssertEqual(remote.map(\.dsn), ["child-1", "child-2"])
        XCTAssertEqual(remote.map(\.name), ["Kid One", "Kid Two"])
        XCTAssertEqual(remote.first?.avatarURL?.absoluteString, "https://example.com/one.jpg")

        let cachedAfterFailure = try await service.fetchDevices(limit: 1)
        XCTAssertEqual(cachedAfterFailure.map(\.id), [1])

        secureTokens.access = nil
        let cachedWithoutAuthorization = try await service.fetchDevices(limit: 2)
        XCTAssertEqual(cachedWithoutAuthorization.map(\.id), [1, 2])
        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.count, 2)
    }

    func testFetchDevicesThrowsRemoteErrorWhenCacheIsEmpty() async {
        let suiteName = "MemberDevicesServiceRemoteFailureTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer access")
        let service = makeMemberDevicesServiceForTests(
            secureTokens: secureTokens,
            userDefaults: userDefaults
        )

        TestHTTPURLProtocol.requestHandler = { request in
            (makeHTTPResponse(for: request.url!, statusCode: 500), Data("server-down".utf8))
        }

        do {
            _ = try await service.fetchDevices(limit: 20)
            XCTFail("Expected fetchDevices to throw when no cache is available")
        } catch let NetworkError.server(statusCode, body) {
            XCTAssertEqual(statusCode, 500)
            XCTAssertEqual(body, "server-down")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolveDeviceMatchesCaseInsensitivelyUsingCachedRecords() async throws {
        let suiteName = "MemberDevicesServiceResolveTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let cachedPayload = try JSONSerialization.data(withJSONObject: [
            [
                "id": 3,
                "dsn": " child-3 ",
                "name": "Kid Three",
                "avatarURL": "https://example.com/three.jpg"
            ],
            [
                "id": 4,
                "dsn": "child-4",
                "name": "Kid Four",
                "avatarURL": NSNull()
            ]
        ])
        userDefaults.set(cachedPayload, forKey: "MEMBER_DEVICES_CACHE_V1")

        let service = makeMemberDevicesServiceForTests(
            secureTokens: MutableSecureTokenStoreSpy(access: nil),
            userDefaults: userDefaults
        )

        let device = try await service.resolveDevice(byDSN: " CHILD-3 ", limit: 50)

        XCTAssertEqual(device.id, 3)
        XCTAssertEqual(device.dsn, " child-3 ")
        XCTAssertEqual(device.name, "Kid Three")
        XCTAssertEqual(device.avatarURL?.absoluteString, "https://example.com/three.jpg")
        XCTAssertTrue(TestHTTPURLProtocol.recordedRequests.isEmpty)
    }

    func testResolveDeviceRejectsBlankOrMissingDSN() async throws {
        let suiteName = "MemberDevicesServiceResolveFailureTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let cachedPayload = try JSONSerialization.data(withJSONObject: [
            [
                "id": 5,
                "dsn": "child-5",
                "name": "Kid Five"
            ]
        ])
        userDefaults.set(cachedPayload, forKey: "MEMBER_DEVICES_CACHE_V1")

        let service = makeMemberDevicesServiceForTests(
            secureTokens: MutableSecureTokenStoreSpy(access: nil),
            userDefaults: userDefaults
        )

        do {
            _ = try await service.resolveDevice(byDSN: "   ", limit: 10)
            XCTFail("Expected blank DSN to fail")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await service.resolveDevice(byDSN: "child-9", limit: 10)
            XCTFail("Expected missing DSN to fail")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class APIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testRequestDataResponsePropagatesServerStatusAndBody() async {
        let client = makeAPIClientForTests(secureTokens: MutableSecureTokenStoreSpy())
        let request = URLRequest(url: URL(string: "https://api.example.test/protected")!)

        TestHTTPURLProtocol.requestHandler = { request in
            (makeHTTPResponse(for: request.url!, statusCode: 503), Data("backend unavailable".utf8))
        }

        do {
            _ = try await client.requestDataResponse(request)
            XCTFail("Expected requestDataResponse to throw")
        } catch let NetworkError.server(statusCode, body) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertEqual(body, "backend unavailable")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestDataResponseWrapsTransportErrors() async {
        let client = makeAPIClientForTests(secureTokens: MutableSecureTokenStoreSpy())
        let request = URLRequest(url: URL(string: "https://api.example.test/protected")!)

        TestHTTPURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.requestDataResponse(request)
            XCTFail("Expected transport error to be wrapped")
        } catch let NetworkError.underlying(error as URLError) {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestDecodableThrowsEnvelopeErrorBeforeDecoding() async {
        struct Response: Decodable {
            let value: String
        }

        let client = makeAPIClientForTests(secureTokens: MutableSecureTokenStoreSpy())
        let request = URLRequest(url: URL(string: "https://api.example.test/protected")!)

        TestHTTPURLProtocol.requestHandler = { request in
            (
                makeHTTPResponse(for: request.url!, statusCode: 200),
                Data(#"{"status":false,"message":"Invalid payload","status_code":422}"#.utf8)
            )
        }

        do {
            _ = try await client.requestDecodable(request, as: Response.self)
            XCTFail("Expected requestDecodable to throw envelope error")
        } catch let NetworkError.server(statusCode, body) {
            XCTAssertEqual(statusCode, 422)
            XCTAssertEqual(body, "Invalid payload")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestDataWithBaseFallbackRetriesNextBaseAfterFailure() async throws {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer access")
        let client = makeAPIClientForTests(secureTokens: secureTokens)
        let firstBase = URL(string: "https://first.example/api")!
        let secondBase = URL(string: "https://second.example/api")!

        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")

            if request.url?.host == "first.example" {
                return (makeHTTPResponse(for: request.url!, statusCode: 503), Data("down".utf8))
            }

            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data("ok".utf8))
        }

        let data = try await client.requestDataWithBaseFallback(
            baseURLs: [firstBase, secondBase],
            path: "devices/status",
            method: .get
        )

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(
            TestHTTPURLProtocol.recordedRequests.compactMap(\.url?.host),
            ["first.example", "second.example"]
        )
        XCTAssertEqual(
            TestHTTPURLProtocol.recordedRequests.compactMap(\.url?.path),
            ["/api/devices/status", "/api/devices/status"]
        )
    }

    func testRequestDataRefreshesAuthorizationAfter401AndRetriesProtectedRequest() async throws {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer expired", refresh: "refresh-1")
        let client = makeAPIClientForTests(secureTokens: secureTokens)
        var request = URLRequest(url: URL(string: "https://api.example.test/protected")!)
        request.setValue("Bearer expired", forHTTPHeaderField: "Authorization")

        TestHTTPURLProtocol.requestHandler = { request in
            switch (request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("/protected", "Bearer expired"):
                return (makeHTTPResponse(for: request.url!, statusCode: 401), Data("expired".utf8))
            case ("/api/auth/refresh_token", _):
                let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["refresh_token"] as? String, "refresh-1")
                return (
                    makeHTTPResponse(for: request.url!, statusCode: 200),
                    Data(#"{"access_token":"refreshed","refresh_token":"refresh-2","token_type":"Bearer"}"#.utf8)
                )
            case ("/protected", "Bearer refreshed"):
                return (makeHTTPResponse(for: request.url!, statusCode: 200), Data("retried".utf8))
            default:
                XCTFail("Unexpected request: \(String(describing: request.url))")
                return (makeHTTPResponse(for: request.url!, statusCode: 500), Data())
            }
        }

        let data = try await client.requestData(request)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "retried")
        XCTAssertEqual(
            TestHTTPURLProtocol.recordedRequests.compactMap(\.url?.path),
            ["/protected", "/api/auth/refresh_token", "/protected"]
        )
        XCTAssertEqual(
            TestHTTPURLProtocol.recordedRequests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer expired", nil, "Bearer refreshed"]
        )
        XCTAssertEqual(secureTokens.access, "Bearer refreshed")
        XCTAssertEqual(secureTokens.refresh, "refresh-2")
    }

    func testRequestDataDoesNotAttemptRefreshForRefreshEndpoint() async {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer expired", refresh: "refresh-1")
        let client = makeAPIClientForTests(secureTokens: secureTokens)
        var request = URLRequest(url: URL(string: "https://api.example.test/api/auth/refresh_token")!)
        request.setValue("Bearer expired", forHTTPHeaderField: "Authorization")

        TestHTTPURLProtocol.requestHandler = { request in
            (makeHTTPResponse(for: request.url!, statusCode: 401), Data("expired".utf8))
        }

        do {
            _ = try await client.requestData(request)
            XCTFail("Expected requestData to throw")
        } catch let NetworkError.server(statusCode, body) {
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(body, "expired")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(secureTokens.setAccessCalls, [])
        XCTAssertEqual(secureTokens.setRefreshCalls, [])
        XCTAssertEqual(secureTokens.clearCallCount, 0)
    }
}

final class SecureTokenStoreTests: XCTestCase {
    private var store: SecureTokenStore!
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        store = SecureTokenStore()
        store.clear()
        suiteName = "SecureTokenStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        store.clear()
        userDefaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    func testSetReadTrimAndClearTokens() {
        store.setAccessToken("  Bearer access-token  ")
        store.setRefreshToken("\n refresh-token \t")

        XCTAssertEqual(store.accessToken(), "Bearer access-token")
        XCTAssertEqual(store.refreshToken(), "refresh-token")

        store.setAccessToken("   ")
        XCTAssertNil(store.accessToken())
        XCTAssertEqual(store.refreshToken(), "refresh-token")

        store.clear()
        XCTAssertNil(store.accessToken())
        XCTAssertNil(store.refreshToken())
    }

    func testMigrateFromUserDefaultsCopiesLegacyTokensAndRemovesDefaults() {
        userDefaults.set("  Bearer legacy-access  ", forKey: "API_ACCESS_TOKEN")
        userDefaults.set(" legacy-refresh ", forKey: "API_REFRESH_TOKEN")

        store.migrateFromUserDefaults(userDefaults)

        XCTAssertEqual(store.accessToken(), "Bearer legacy-access")
        XCTAssertEqual(store.refreshToken(), "legacy-refresh")
        XCTAssertNil(userDefaults.string(forKey: "API_ACCESS_TOKEN"))
        XCTAssertNil(userDefaults.string(forKey: "API_REFRESH_TOKEN"))
    }

    func testMigrateFromUserDefaultsDoesNotOverwriteExistingTokens() {
        store.setAccessToken("Bearer current-access")
        store.setRefreshToken("current-refresh")
        userDefaults.set("Bearer legacy-access", forKey: "API_ACCESS_TOKEN")
        userDefaults.set("legacy-refresh", forKey: "API_REFRESH_TOKEN")

        store.migrateFromUserDefaults(userDefaults)

        XCTAssertEqual(store.accessToken(), "Bearer current-access")
        XCTAssertEqual(store.refreshToken(), "current-refresh")
        XCTAssertNil(userDefaults.string(forKey: "API_ACCESS_TOKEN"))
        XCTAssertNil(userDefaults.string(forKey: "API_REFRESH_TOKEN"))
    }
}

final class APITokenRefreshServiceTests: XCTestCase {
    func testRefreshAuthorizationHeaderReturnsNilWithoutRefreshToken() async throws {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer old", refresh: nil)
        let service = makeTokenRefreshServiceForTests(secureTokens: secureTokens)
        var requestCallCount = 0

        let header = try await service.refreshAuthorizationHeader { _ in
            requestCallCount += 1
            return Data()
        }

        XCTAssertNil(header)
        XCTAssertEqual(requestCallCount, 0)
        XCTAssertEqual(secureTokens.access, "Bearer old")
    }

    func testRefreshAuthorizationHeaderBuildsRequestAndUpdatesTokens() async throws {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer old", refresh: "refresh-1")
        let service = makeTokenRefreshServiceForTests(secureTokens: secureTokens)

        let header = try await service.refreshAuthorizationHeader { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/auth/refresh_token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["refresh_token"] as? String, "refresh-1")
            return Data(#"{"access_token":"new-access","refresh_token":"refresh-2","token_type":"Bearer"}"#.utf8)
        }

        XCTAssertEqual(header, "Bearer new-access")
        XCTAssertEqual(secureTokens.access, "Bearer new-access")
        XCTAssertEqual(secureTokens.refresh, "refresh-2")
        XCTAssertEqual(secureTokens.setAccessCalls.last!, "Bearer new-access")
        XCTAssertEqual(secureTokens.setRefreshCalls.last!, "refresh-2")
    }

    func testRefreshAuthorizationHeaderKeepsSpacedAccessTokenAndIgnoresBlankRefreshToken() async throws {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer old", refresh: "refresh-keep")
        let service = makeTokenRefreshServiceForTests(secureTokens: secureTokens)

        let header = try await service.refreshAuthorizationHeader { _ in
            Data(#"{"access_token":"Token already formatted","refresh_token":"   ","token_type":"Bearer"}"#.utf8)
        }

        XCTAssertEqual(header, "Token already formatted")
        XCTAssertEqual(secureTokens.access, "Token already formatted")
        XCTAssertEqual(secureTokens.refresh, "refresh-keep")
        XCTAssertEqual(secureTokens.setRefreshCalls.count, 0)
    }

    func testRefreshAuthorizationHeaderReturnsNilWhenResponseHasNoAccessToken() async throws {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer old", refresh: "refresh-1")
        let service = makeTokenRefreshServiceForTests(secureTokens: secureTokens)

        let header = try await service.refreshAuthorizationHeader { _ in
            Data(#"{"access_token":"   ","refresh_token":"refresh-2","token_type":"Bearer"}"#.utf8)
        }

        XCTAssertNil(header)
        XCTAssertEqual(secureTokens.access, "Bearer old")
        XCTAssertEqual(secureTokens.refresh, "refresh-1")
    }

    func testRefreshAuthorizationHeaderClearsTokensForAuthenticationFailures() async throws {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer old", refresh: "refresh-1")
        let service = makeTokenRefreshServiceForTests(secureTokens: secureTokens)

        let header = try await service.refreshAuthorizationHeader { _ in
            Data(#"{"status":false,"message":"Expired","status_code":401}"#.utf8)
        }

        XCTAssertNil(header)
        XCTAssertNil(secureTokens.access)
        XCTAssertNil(secureTokens.refresh)
        XCTAssertEqual(secureTokens.clearCallCount, 1)
    }

    func testRefreshAuthorizationHeaderRethrowsLastTransportError() async {
        enum RefreshTestError: Error {
            case offline
        }

        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer old", refresh: "refresh-1")
        let service = makeTokenRefreshServiceForTests(secureTokens: secureTokens)

        do {
            _ = try await service.refreshAuthorizationHeader { _ in
                throw RefreshTestError.offline
            }
            XCTFail("Expected refresh to rethrow transport error")
        } catch RefreshTestError.offline {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(secureTokens.clearCallCount, 0)
        XCTAssertEqual(secureTokens.access, "Bearer old")
        XCTAssertEqual(secureTokens.refresh, "refresh-1")
    }
}

final class APIAuthRefreshCoordinatorTests: XCTestCase {
    func testRefreshSharesSingleInFlightTaskAcrossConcurrentCallers() async throws {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer old", refresh: "refresh-1")
        let service = makeTokenRefreshServiceForTests(secureTokens: secureTokens)
        let coordinator = APIAuthRefreshCoordinator()
        let requestSpy = RefreshRequestDataSpy(
            responses: [Data(#"{"access_token":"shared-access","refresh_token":"refresh-2","token_type":"Bearer"}"#.utf8)],
            suspendFirstCall: true
        )

        let first = Task {
            try await coordinator.refresh(using: service) { request in
                try await requestSpy.requestData(for: request)
            }
        }

        await waitForRefreshRequestCount(requestSpy, count: 1)

        let second = Task {
            try await coordinator.refresh(using: service) { request in
                try await requestSpy.requestData(for: request)
            }
        }

        await Task.yield()
        let inFlightRequestCount = await requestSpy.recordedRequests().count
        XCTAssertEqual(inFlightRequestCount, 1)

        await requestSpy.resumeSuspendedCallIfNeeded()

        let firstHeader = try await first.value
        let secondHeader = try await second.value

        XCTAssertEqual(firstHeader, "Bearer shared-access")
        XCTAssertEqual(secondHeader, "Bearer shared-access")
        let finalRequestCount = await requestSpy.recordedRequests().count
        XCTAssertEqual(finalRequestCount, 1)
        XCTAssertEqual(secureTokens.setAccessCalls, ["Bearer shared-access"])
        XCTAssertEqual(secureTokens.setRefreshCalls, ["refresh-2"])
    }

    func testRefreshStartsNewTaskAfterPreviousRefreshCompletes() async throws {
        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer old", refresh: "refresh-1")
        let service = makeTokenRefreshServiceForTests(secureTokens: secureTokens)
        let coordinator = APIAuthRefreshCoordinator()
        let requestSpy = RefreshRequestDataSpy(responses: [
            Data(#"{"access_token":"access-1","refresh_token":"refresh-2","token_type":"Bearer"}"#.utf8),
            Data(#"{"access_token":"access-2","refresh_token":"refresh-3","token_type":"Bearer"}"#.utf8)
        ])

        let firstHeader = try await coordinator.refresh(using: service) { request in
            try await requestSpy.requestData(for: request)
        }
        let secondHeader = try await coordinator.refresh(using: service) { request in
            try await requestSpy.requestData(for: request)
        }

        let requestCount = await requestSpy.recordedRequests().count
        XCTAssertEqual(firstHeader, "Bearer access-1")
        XCTAssertEqual(secondHeader, "Bearer access-2")
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(secureTokens.setAccessCalls, ["Bearer access-1", "Bearer access-2"])
        XCTAssertEqual(secureTokens.setRefreshCalls, ["refresh-2", "refresh-3"])
    }
}

final class DeviceApplicationRemovalAttemptCoordinatorTests: XCTestCase {
    func testEnqueueIgnoresInvalidEntries() async {
        let service = DeviceApplicationRemovalAttemptServiceSpy()
        let coordinator = DeviceApplicationRemovalAttemptCoordinator(service: service)

        await coordinator.enqueue(dsn: "   ", packageName: "com.example.one", appName: "Example")
        await coordinator.enqueue(dsn: "child-1", packageName: "   ", appName: "Example")
        await coordinator.enqueue(dsn: "child-1", packageName: "com.example.one", appName: "   ")

        let recordedCalls = await service.recordedCalls()
        XCTAssertTrue(recordedCalls.isEmpty)
    }

    func testEnqueueNormalizesValuesAndProcessesImmediately() async {
        let service = DeviceApplicationRemovalAttemptServiceSpy()
        let coordinator = DeviceApplicationRemovalAttemptCoordinator(service: service)

        await coordinator.enqueue(
            dsn: " child-1 ",
            packageName: " COM.EXAMPLE.APP ",
            appName: " Example App "
        )

        let recordedCalls = await service.recordedCalls()
        XCTAssertEqual(
            recordedCalls,
            [
                DeviceApplicationRemovalAttemptEntry(
                    dsn: "child-1",
                    packageName: "com.example.app",
                    appName: "Example App"
                )
            ]
        )
    }

    func testEnqueueDeduplicatesInFlightEntriesAndProcessesDistinctEntriesInOrder() async {
        let service = DeviceApplicationRemovalAttemptServiceSpy(suspendFirstCall: true)
        let coordinator = DeviceApplicationRemovalAttemptCoordinator(service: service)

        let first = Task {
            await coordinator.enqueue(
                dsn: " child-1 ",
                packageName: " COM.EXAMPLE.APP ",
                appName: " Example App "
            )
        }

        await waitForRemovalAttemptCallCount(service, count: 1)

        let duplicate = Task {
            await coordinator.enqueue(
                dsn: "child-1",
                packageName: "com.example.app",
                appName: "Example App"
            )
        }
        let second = Task {
            await coordinator.enqueue(
                dsn: "child-1",
                packageName: "com.example.second",
                appName: "Second App"
            )
        }

        await Task.yield()
        await service.resumeSuspendedCallIfNeeded()
        _ = await (first.result, duplicate.result, second.result)
        await waitForRemovalAttemptCallCount(service, count: 2)

        let recordedCalls = await service.recordedCalls()
        XCTAssertEqual(
            recordedCalls,
            [
                DeviceApplicationRemovalAttemptEntry(
                    dsn: "child-1",
                    packageName: "com.example.app",
                    appName: "Example App"
                ),
                DeviceApplicationRemovalAttemptEntry(
                    dsn: "child-1",
                    packageName: "com.example.second",
                    appName: "Second App"
                )
            ]
        )
    }
}

final class DeviceApplicationStateServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testFetchStateBuildsRequestsAndAggregatesLockedApplications() async throws {
        let memberDevices = MemberDevicesResolutionServiceSpy(
            resolveDeviceResult: .success(
                MemberDeviceRecord(id: 42, dsn: "child-42", name: "Kid Forty Two", avatarURL: nil)
            )
        )
        let expectedPaths = Set([
            "/api/members/device/v2/42/applications"
        ])

        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")

            switch request.url?.path {
            case "/api/members/device/v2/42/applications":
                let payload = #"""
                [
                  {
                    "package_name": " com.example.chat ",
                    "name": " Chat App ",
                    "is_locked": true
                  },
                  {
                    "package_name": " COM.example.mail ",
                    "name": " Mail App ",
                    "is_locked": true
                  },
                  {
                    "package_name": "com.example.free",
                    "name": "Free App",
                    "is_locked": false
                  }
                ]
                """#.data(using: .utf8)!
                return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return (makeHTTPResponse(for: request.url!, statusCode: 404), Data())
            }
        }

        let service = DeviceApplicationStateService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            memberDevicesService: memberDevices
        )

        let result = try await service.fetchState(dsn: " child-42 ")

        let resolvedArguments = await memberDevices.recordedResolvedArguments()

        XCTAssertEqual(resolvedArguments, [
            MemberDeviceResolutionCall(dsn: " child-42 ", limit: 100)
        ])
        XCTAssertEqual(Set(TestHTTPURLProtocol.recordedRequests.compactMap(\.url?.path)), expectedPaths)
        XCTAssertEqual(result.deviceID, 42)
        XCTAssertEqual(result.applicationsEndpoint, "members/device/v2/42/applications")
        XCTAssertEqual(result.remoteLockedApplications, [
            DeviceAppSelectionApplication(packageName: "com.example.chat", appName: "Chat App"),
            DeviceAppSelectionApplication(packageName: "com.example.mail", appName: "Mail App")
        ])
        XCTAssertEqual(result.remoteLockedIdentifiers, [
            "com.example.chat",
            "com.example.mail"
        ])
        XCTAssertEqual(result.payloadSummary, "3 apps, 2 locked")
    }

    func testFetchStateDefaultsNullPayloadsToEmptyCollections() async throws {
        let memberDevices = MemberDevicesResolutionServiceSpy(
            resolveDeviceResult: .success(
                MemberDeviceRecord(id: 7, dsn: "child-7", name: "Kid Seven", avatarURL: nil)
            )
        )

        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/members/device/v2/7/applications")
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data("null".utf8))
        }

        let service = DeviceApplicationStateService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            memberDevicesService: memberDevices
        )

        let result = try await service.fetchState(dsn: "child-7")

        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertTrue(result.remoteLockedApplications.isEmpty)
        XCTAssertEqual(result.payloadSummary, "0 apps, 0 locked")
    }

    func testRemoteLockedApplicationsNormalizeAndSortLockedEntries() {
        let result = DeviceApplicationStateFetchResult(
            deviceID: 5,
            applicationsEndpoint: "applications",
            applications: [
                DeviceApplicationRecord(
                    packageName: " COM.example.chat ",
                    name: " Chat App ",
                    isLocked: true,
                    lockEndTime: nil
                ),
                DeviceApplicationRecord(
                    packageName: "com.example.fallback",
                    name: "   ",
                    isLocked: true,
                    lockEndTime: nil
                ),
                DeviceApplicationRecord(
                    packageName: "   ",
                    name: "Ignored",
                    isLocked: true,
                    lockEndTime: nil
                ),
                DeviceApplicationRecord(
                    packageName: "com.example.unlocked",
                    name: "Unlocked",
                    isLocked: false,
                    lockEndTime: nil
                )
            ]
        )

        // Sorted by appName: the fallback name is now "Bolajon360" (was the raw key
        // "common.app_default" before that key was defined), so it sorts before "Chat App".
        XCTAssertEqual(result.remoteLockedApplications, [
            DeviceAppSelectionApplication(
                packageName: "com.example.fallback",
                appName: ProductFallbackText.appName()
            ),
            DeviceAppSelectionApplication(packageName: "com.example.chat", appName: "Chat App")
        ])
        XCTAssertEqual(result.payloadSummary, "4 apps, 2 locked")
    }
}

final class DeviceAppLimitServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testFetchLimitsBuildsAuthorizedRequestAndDecodesPayload() async throws {
        let memberDevices = MemberDevicesResolutionServiceSpy(
            resolveDeviceResult: .success(
                MemberDeviceRecord(id: 13, dsn: "child-13", name: "Kid Thirteen", avatarURL: nil)
            )
        )

        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/members/device/v2/13/applications")
            XCTAssertEqual(
                Set(request.url?.query?.split(separator: "&").map(String.init) ?? []),
                Set(["is_limit_enabled=true"])
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")

            let payload = #"""
            [
              {
                "package_name": "com.example.chat",
                "daily_limit_minutes": 45,
                "is_limit_enabled": true,
                "used_today_seconds": 600,
                "remaining_today_seconds": 2100,
                "is_limit_reached": false
              }
            ]
            """#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = DeviceAppLimitService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            memberDevicesService: memberDevices
        )

        let result = try await service.fetchLimits(dsn: "child-13")

        let resolvedArguments = await memberDevices.recordedResolvedArguments()

        XCTAssertEqual(resolvedArguments, [
            MemberDeviceResolutionCall(dsn: "child-13", limit: 100)
        ])
        XCTAssertEqual(result.deviceID, 13)
        XCTAssertEqual(result.endpoint, "members/device/v2/13/applications?is_limit_enabled=true")
        XCTAssertEqual(result.limits, [
            DeviceAppLimitResponse(
                packageName: "com.example.chat",
                dailyLimitMinutes: 45,
                isLimitEnabled: true,
                usedTodaySeconds: 600,
                remainingTodaySeconds: 2100,
                isLimitReached: false
            )
        ])
    }
}

final class DeviceAppLockSyncCoordinatorTests: XCTestCase {
    func testUpdateNormalizesDSNSortsEntriesAndSkipsEquivalentSignatures() async {
        let service = DeviceAppLockSyncServiceSpy()
        let coordinator = DeviceAppLockSyncCoordinator(service: service)
        let alpha = DeviceAppLockSyncEntry(
            packageName: "com.example.alpha",
            appName: "Alpha",
            isLocked: true,
            usedTime: 10
        )
        let beta = DeviceAppLockSyncEntry(
            packageName: "com.example.beta",
            appName: "Beta",
            isLocked: false,
            usedTime: 20
        )

        await coordinator.update(dsn: " child-sync ", entries: [beta, alpha])
        await coordinator.update(dsn: "child-sync", entries: [alpha, beta])

        let recordedCalls = await service.recordedCalls()

        XCTAssertEqual(recordedCalls, [
            DeviceAppLockSyncCall(
                dsn: "child-sync",
                entries: [alpha, beta]
            )
        ])
    }

    func testRetryNowForcesSyncForUnchangedState() async {
        let service = DeviceAppLockSyncServiceSpy()
        let coordinator = DeviceAppLockSyncCoordinator(service: service)
        let entry = DeviceAppLockSyncEntry(
            packageName: "com.example.camera",
            appName: "Camera",
            isLocked: true,
            usedTime: 33
        )

        await coordinator.update(dsn: "child-sync", entries: [entry])
        await coordinator.retryNow()

        let recordedCalls = await service.recordedCalls()

        XCTAssertEqual(recordedCalls, [
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry]),
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry])
        ])
    }

    func testBlankDSNResetsSignatureAndAllowsFutureResync() async {
        let service = DeviceAppLockSyncServiceSpy()
        let coordinator = DeviceAppLockSyncCoordinator(service: service)
        let entry = DeviceAppLockSyncEntry(
            packageName: "com.example.mail",
            appName: "Mail",
            isLocked: false,
            usedTime: 5
        )

        await coordinator.update(dsn: "child-sync", entries: [entry])
        await coordinator.update(dsn: "   ", entries: [entry])
        await coordinator.update(dsn: "child-sync", entries: [entry])

        let recordedCalls = await service.recordedCalls()

        XCTAssertEqual(recordedCalls, [
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry]),
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry])
        ])
    }

    func testFailureSchedulesRetryUntilStateIsCleared() async {
        let service = DeviceAppLockSyncServiceSpy(results: [.failure(DeviceAppLockSyncTestError.offline)])
        let coordinator = DeviceAppLockSyncCoordinator(service: service)
        let entry = DeviceAppLockSyncEntry(
            packageName: "com.example.maps",
            appName: "Maps",
            isLocked: true,
            usedTime: 12
        )

        await coordinator.update(dsn: "child-sync", entries: [entry])
        await coordinator.update(dsn: nil, entries: [])

        let recordedCalls = await service.recordedCalls()

        XCTAssertEqual(recordedCalls, [
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry])
        ])
    }
}

final class DeviceApplicationUsageReportCoordinatorTests: XCTestCase {
    func testUpdateSnapshotUploadsOnlyDeltaUsageForTheCurrentDay() async {
        let service = DeviceApplicationUsageReportServiceSpy(
            results: [
                .success(.init(lockedPackages: [], stats: [])),
                .success(.init(lockedPackages: [], stats: []))
            ]
        )
        let suiteName = "DeviceApplicationUsageReportCoordinatorTests.delta.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let coordinator = DeviceApplicationUsageReportCoordinator(
            service: service,
            userDefaults: userDefaults,
            responseHandler: { _, _ in },
            diagnosticsUpdater: { _, _, _, _, _, _, _, _ in },
            retryScheduler: { _, _ in Task {} }
        )

        await coordinator.updateDSN("child-usage")
        await coordinator.updateSnapshot(
            makeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-19",
                entries: [
                    .init(packageName: "com.example.chat", appName: "Chat", usedTime: 120),
                    .init(packageName: "com.example.maps", appName: "Maps", usedTime: 60)
                ]
            )
        )
        await coordinator.updateSnapshot(
            makeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-19",
                entries: [
                    .init(packageName: "com.example.chat", appName: "Chat", usedTime: 180),
                    .init(packageName: "com.example.maps", appName: "Maps", usedTime: 60)
                ]
            )
        )

        let recordedCalls = await service.recordedCalls()
        let pendingBatchCount = await coordinator.pendingBatchCount()

        XCTAssertEqual(recordedCalls, [
            DeviceApplicationUsageReportCall(
                dsn: "child-usage",
                items: [
                    DeviceApplicationUsageReportItemRequest(packageName: "com.example.chat", usedSeconds: 120),
                    DeviceApplicationUsageReportItemRequest(packageName: "com.example.maps", usedSeconds: 60)
                ]
            ),
            DeviceApplicationUsageReportCall(
                dsn: "child-usage",
                items: [
                    DeviceApplicationUsageReportItemRequest(packageName: "com.example.chat", usedSeconds: 60)
                ]
            )
        ])
        XCTAssertEqual(pendingBatchCount, 0)
    }

    func testFailedUploadPersistsQueueUntilANewCoordinatorRetriesIt() async {
        let suiteName = "DeviceApplicationUsageReportCoordinatorTests.retry.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let failingService = DeviceApplicationUsageReportServiceSpy(
            results: [.failure(DeviceApplicationUsageReportTestError.offline)]
        )
        let firstCoordinator = DeviceApplicationUsageReportCoordinator(
            service: failingService,
            userDefaults: userDefaults,
            responseHandler: { _, _ in },
            diagnosticsUpdater: { _, _, _, _, _, _, _, _ in },
            retryScheduler: { _, _ in Task {} }
        )

        await firstCoordinator.updateDSN("child-usage")
        await firstCoordinator.updateSnapshot(
            makeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-19",
                entries: [
                    .init(packageName: "com.example.chat", appName: "Chat", usedTime: 240)
                ]
            )
        )

        let firstPendingBatchCount = await firstCoordinator.pendingBatchCount()
        let failingCalls = await failingService.recordedCalls()

        XCTAssertEqual(firstPendingBatchCount, 1)
        XCTAssertEqual(failingCalls, [
            DeviceApplicationUsageReportCall(
                dsn: "child-usage",
                items: [DeviceApplicationUsageReportItemRequest(packageName: "com.example.chat", usedSeconds: 240)]
            )
        ])

        let succeedingService = DeviceApplicationUsageReportServiceSpy(
            results: [.success(.init(
                lockedPackages: ["com.example.chat"],
                stats: [
                    DeviceApplicationUsageReportStat(
                        packageName: "com.example.chat",
                        usageDate: "2026-03-19",
                        usedSeconds: 240,
                        dailyLimitSeconds: 300,
                        remainingSeconds: 60,
                        isLimitReached: false
                    )
                ]
            ))]
        )
        let secondCoordinator = DeviceApplicationUsageReportCoordinator(
            service: succeedingService,
            userDefaults: userDefaults,
            responseHandler: { _, _ in },
            diagnosticsUpdater: { _, _, _, _, _, _, _, _ in },
            retryScheduler: { _, _ in Task {} }
        )

        await secondCoordinator.updateDSN("child-usage")

        let succeedingCalls = await succeedingService.recordedCalls()
        let secondPendingBatchCount = await secondCoordinator.pendingBatchCount()

        XCTAssertEqual(succeedingCalls, [
            DeviceApplicationUsageReportCall(
                dsn: "child-usage",
                items: [DeviceApplicationUsageReportItemRequest(packageName: "com.example.chat", usedSeconds: 240)]
            )
        ])
        XCTAssertEqual(secondPendingBatchCount, 0)
    }

    private func makeUsageSnapshot(
        dsn: String,
        dayKey: String,
        entries: [ScreenTimeUsageSnapshotEntry]
    ) -> ScreenTimeUsageSnapshot {
        ScreenTimeUsageSnapshot(
            dsn: dsn,
            dayKey: dayKey,
            generatedAt: Date(timeIntervalSince1970: 1_742_339_200),
            entries: entries
        )
    }
}

final class SessionStoreTests: XCTestCase {
    override func tearDown() {
        L10n.setLanguage(AppLanguage.defaultForDevice.rawValue)
        super.tearDown()
    }

    func testInitLoadsPersistedValuesAndMigratesSecureTokens() {
        let suiteName = "SessionStoreInitTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set(" child-1 ", forKey: "DSN")
        userDefaults.set("Parent", forKey: "PROFILE_NAME")
        userDefaults.set(AppTheme.dark.rawValue, forKey: "APP_THEME")
        userDefaults.set(AppLanguage.uz.rawValue, forKey: "APP_LANGUAGE")

        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer access", refresh: "refresh-1")
        let store = SessionStore(userDefaults: userDefaults, secureTokens: secureTokens)

        XCTAssertEqual(secureTokens.migrateCallCount, 1)
        XCTAssertEqual(store.dsn, "child-1")
        XCTAssertEqual(store.profileName, "Parent")
        XCTAssertEqual(store.apiAccessToken, "Bearer access")
        XCTAssertEqual(store.apiRefreshToken, "refresh-1")
        XCTAssertEqual(store.appTheme, .dark)
        XCTAssertEqual(store.appLanguage, .uz)
    }

    func testInitFallsBackForInvalidPersistedThemeLanguageAndProfile() {
        let suiteName = "SessionStoreFallbackTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("   ", forKey: "DSN")
        userDefaults.set("unknown", forKey: "APP_THEME")
        userDefaults.set("xx", forKey: "APP_LANGUAGE")

        let store = SessionStore(
            userDefaults: userDefaults,
            secureTokens: MutableSecureTokenStoreSpy()
        )

        XCTAssertNil(store.dsn)
        XCTAssertEqual(store.profileName, L10n.tr("common.user_default"))
        XCTAssertEqual(store.appTheme, .system)
        XCTAssertEqual(store.appLanguage, AppLanguage.defaultForDevice)
    }

    func testSettersPersistNormalizedValuesAndClearSession() {
        let suiteName = "SessionStoreMutationTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let secureTokens = MutableSecureTokenStoreSpy()
        let store = SessionStore(userDefaults: userDefaults, secureTokens: secureTokens)

        store.setDSN(" child-2 ")
        store.setProfileName("Guardian")
        store.setAPIAccessToken("  Bearer   access-token  ")
        store.setAPIRefreshToken("refresh-2")
        store.setTheme(.light)
        store.setLanguage(.ru)

        XCTAssertEqual(store.dsn, "child-2")
        XCTAssertEqual(userDefaults.string(forKey: "DSN"), "child-2")
        XCTAssertEqual(store.profileName, "Guardian")
        XCTAssertEqual(userDefaults.string(forKey: "PROFILE_NAME"), "Guardian")
        XCTAssertEqual(store.apiAccessToken, "Bearer access-token")
        XCTAssertEqual(secureTokens.setAccessCalls.last!, "Bearer access-token")
        XCTAssertEqual(store.apiRefreshToken, "refresh-2")
        XCTAssertEqual(secureTokens.setRefreshCalls.last!, "refresh-2")
        XCTAssertEqual(store.appTheme, .light)
        XCTAssertEqual(userDefaults.string(forKey: "APP_THEME"), AppTheme.light.rawValue)
        XCTAssertEqual(store.appLanguage, .ru)
        XCTAssertEqual(userDefaults.string(forKey: "APP_LANGUAGE"), AppLanguage.ru.rawValue)
        XCTAssertTrue(store.hasAuthenticatedSession)

        store.clearSession()

        XCTAssertNil(store.dsn)
        XCTAssertNil(userDefaults.string(forKey: "DSN"))
        XCTAssertNil(store.apiAccessToken)
        XCTAssertNil(store.apiRefreshToken)
        XCTAssertNil(secureTokens.access)
        XCTAssertNil(secureTokens.refresh)
        XCTAssertEqual(store.profileName, "Guardian")
        XCTAssertEqual(store.appTheme, .light)
        XCTAssertEqual(store.appLanguage, .ru)
        XCTAssertFalse(store.hasAuthenticatedSession)
    }

    func testClearSessionRegeneratesDeviceDSNAndClearsGlobalCache() {
        let suiteName = "SessionStorePurgeTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = SessionStore(userDefaults: userDefaults, secureTokens: MutableSecureTokenStoreSpy())

        // Simulate a paired child: a generate-once device DSN + a globally-cached device list.
        let dsnBefore = OilaDeviceIdentity.deviceDSN(userDefaults: userDefaults)
        userDefaults.set(Data("x".utf8), forKey: "SETTINGS_CACHE_CONNECTED_DEVICES")
        userDefaults.set("Aziz", forKey: "SETTINGS_CACHE_PROFILE_NAME")

        store.clearSession()

        // A different child re-pairing on this device must get a FRESH DSN scope...
        let dsnAfter = OilaDeviceIdentity.deviceDSN(userDefaults: userDefaults)
        XCTAssertNotEqual(dsnBefore, dsnAfter)
        // ...and the previous child's globally-cached data must be gone.
        XCTAssertNil(userDefaults.data(forKey: "SETTINGS_CACHE_CONNECTED_DEVICES"))
        XCTAssertNil(userDefaults.string(forKey: "SETTINGS_CACHE_PROFILE_NAME"))
    }

    func testRoutingMigrationSendsLegacyLinkedUserThroughFullOnboarding() {
        let suiteName = "SessionStoreMigrationTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        // A legacy-linked user (has a DSN) who has never run the new routing migration.
        userDefaults.set("legacy-dsn", forKey: "DSN")

        let store = SessionStore(userDefaults: userDefaults, secureTokens: MutableSecureTokenStoreSpy())

        // They must re-pair AND re-run the B1–B11 permission flow (not skip it): the new flow's
        // permissions (Always-location, Screen Time authorization) may never have been granted.
        XCTAssertFalse(store.setupCompleted)
        XCTAssertFalse(store.onboardingCompleted)
        XCTAssertFalse(store.oilaPaired)
    }

    func testHasAuthenticatedSessionUsesRefreshTokenWhenAccessTokenIsMissing() {
        let suiteName = "SessionStoreRefreshOnlyTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = SessionStore(
            userDefaults: userDefaults,
            secureTokens: MutableSecureTokenStoreSpy(access: nil, refresh: "refresh-only")
        )

        XCTAssertNil(store.apiAccessToken)
        XCTAssertEqual(store.apiRefreshToken, "refresh-only")
        XCTAssertTrue(store.hasAuthenticatedSession)
    }
}

private final class MutableSecureTokenStoreSpy: SecureTokenStoring {
    var access: String?
    var refresh: String?
    private(set) var setAccessCalls: [String?] = []
    private(set) var setRefreshCalls: [String?] = []
    private(set) var clearCallCount = 0
    private(set) var migrateCallCount = 0

    init(access: String? = nil, refresh: String? = nil) {
        self.access = access
        self.refresh = refresh
    }

    func accessToken() -> String? { access }
    func refreshToken() -> String? { refresh }

    func setAccessToken(_ token: String?) {
        access = token
        setAccessCalls.append(token)
    }

    func setRefreshToken(_ token: String?) {
        refresh = token
        setRefreshCalls.append(token)
    }

    func migrateFromUserDefaults(_ userDefaults: UserDefaults) {
        migrateCallCount += 1
    }

    func clear() {
        clearCallCount += 1
        access = nil
        refresh = nil
    }
}

private actor RefreshRequestDataSpy {
    private var requests: [URLRequest] = []
    private var responses: [Data]
    private let suspendFirstCall: Bool
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        responses: [Data],
        suspendFirstCall: Bool = false
    ) {
        self.responses = responses
        self.suspendFirstCall = suspendFirstCall
    }

    func requestData(for request: URLRequest) async throws -> Data {
        requests.append(request)

        if suspendFirstCall, shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        if responses.count > 1 {
            return responses.removeFirst()
        }

        return responses.first ?? Data()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func resumeSuspendedCallIfNeeded() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DeviceApplicationRemovalAttemptServiceSpy: DeviceApplicationRemovalAttemptServicing {
    private var calls: [DeviceApplicationRemovalAttemptEntry] = []
    private let suspendFirstCall: Bool
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?

    init(suspendFirstCall: Bool = false) {
        self.suspendFirstCall = suspendFirstCall
    }

    func reportRemovalAttempt(dsn: String, packageName: String, appName: String) async throws {
        calls.append(
            DeviceApplicationRemovalAttemptEntry(
                dsn: dsn,
                packageName: packageName,
                appName: appName
            )
        )

        if suspendFirstCall, shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    func recordedCalls() -> [DeviceApplicationRemovalAttemptEntry] {
        calls
    }

    func resumeSuspendedCallIfNeeded() {
        continuation?.resume()
        continuation = nil
    }
}

private struct DeviceAppLockSyncCall: Equatable {
    let dsn: String
    let entries: [DeviceAppLockSyncEntry]
}

private struct MemberDeviceResolutionCall: Equatable {
    let dsn: String
    let limit: Int
}

private enum DeviceAppLockSyncTestError: Error {
    case offline
}

private enum DeviceApplicationUsageReportTestError: Error {
    case offline
}

private actor DeviceAppLockSyncServiceSpy: DeviceAppLockSyncServicing {
    private var calls: [DeviceAppLockSyncCall] = []
    private var results: [Result<Void, Error>]

    init(results: [Result<Void, Error>] = [.success(())]) {
        self.results = results
    }

    func syncApplications(_ entries: [DeviceAppLockSyncEntry], dsn: String) async throws {
        calls.append(DeviceAppLockSyncCall(dsn: dsn, entries: entries))

        if results.count > 1 {
            return try results.removeFirst().get()
        }

        return try results.first?.get() ?? ()
    }

    func recordedCalls() -> [DeviceAppLockSyncCall] {
        calls
    }
}

private struct DeviceApplicationUsageReportCall: Equatable {
    let dsn: String
    let items: [DeviceApplicationUsageReportItemRequest]
}

private actor DeviceApplicationUsageReportServiceSpy: DeviceApplicationUsageReportServicing {
    private var calls: [DeviceApplicationUsageReportCall] = []
    private var results: [Result<DeviceApplicationUsageReportResponse, Error>]

    init(
        results: [Result<DeviceApplicationUsageReportResponse, Error>] = [
            .success(DeviceApplicationUsageReportResponse(lockedPackages: [], stats: []))
        ]
    ) {
        self.results = results
    }

    func reportUsage(
        dsn: String,
        items: [DeviceApplicationUsageReportItemRequest]
    ) async throws -> DeviceApplicationUsageReportResponse {
        calls.append(DeviceApplicationUsageReportCall(dsn: dsn, items: items))

        if results.count > 1 {
            return try results.removeFirst().get()
        }

        return try results.first?.get() ?? DeviceApplicationUsageReportResponse(lockedPackages: [], stats: [])
    }

    func recordedCalls() -> [DeviceApplicationUsageReportCall] {
        calls
    }
}

private actor MemberDevicesResolutionServiceSpy: MemberDevicesServicing {
    private let resolveDeviceResult: Result<MemberDeviceRecord, Error>
    private let fetchDevicesResult: Result<[MemberDeviceRecord], Error>
    private var resolvedArguments: [MemberDeviceResolutionCall] = []

    init(
        fetchDevicesResult: Result<[MemberDeviceRecord], Error> = .success([]),
        resolveDeviceResult: Result<MemberDeviceRecord, Error>
    ) {
        self.fetchDevicesResult = fetchDevicesResult
        self.resolveDeviceResult = resolveDeviceResult
    }

    func fetchDevices(limit: Int) async throws -> [MemberDeviceRecord] {
        try fetchDevicesResult.get()
    }

    func resolveDevice(byDSN dsn: String, limit: Int) async throws -> MemberDeviceRecord {
        resolvedArguments.append(MemberDeviceResolutionCall(dsn: dsn, limit: limit))
        return try resolveDeviceResult.get()
    }

    func recordedResolvedArguments() -> [MemberDeviceResolutionCall] {
        resolvedArguments
    }
}

private func makeAPIClientForTests(
    secureTokens: SecureTokenStoring
) -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestHTTPURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return APIClient(session: session, secureTokens: secureTokens)
}

private func makeMemberDevicesServiceForTests(
    secureTokens: SecureTokenStoring,
    userDefaults: UserDefaults
) -> MemberDevicesService {
    let client = makeAPIClientForTests(secureTokens: secureTokens)
    return MemberDevicesService(
        client: client,
        secureTokens: secureTokens,
        userDefaults: userDefaults
    )
}

private func makeTokenRefreshServiceForTests(
    secureTokens: SecureTokenStoring
) -> APITokenRefreshService {
    APITokenRefreshService(
        requestFactory: APIRequestFactory(secureTokens: secureTokens),
        responseDecoder: APIResponseDecoder(decoder: JSONDecoder()),
        secureTokens: secureTokens
    )
}

private func waitForRemovalAttemptCallCount(
    _ service: DeviceApplicationRemovalAttemptServiceSpy,
    count: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let currentCount = await service.recordedCalls().count
        if currentCount >= count {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func waitForRefreshRequestCount(
    _ spy: RefreshRequestDataSpy,
    count: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

    while DispatchTime.now().uptimeNanoseconds < deadline {
        let currentCount = await spy.recordedRequests().count
        if currentCount >= count {
            return
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Regression coverage for the `POST /device/apps/usage` response contract: the live backend can
/// send a sparse/null payload (proven by Android's nullable UsageReportResponse), so decoding must
/// never throw — a throw would fail the batch, retry the same delta forever, and starve enforcement.
final class DeviceApplicationUsageReportDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> DeviceApplicationUsageReportResponse {
        try JSONDecoder().decode(DeviceApplicationUsageReportResponse.self, from: Data(json.utf8))
    }

    func testDecodesEmptyObjectToEmptyEnforcementStateWithoutThrowing() throws {
        let response = try decode("{}")
        XCTAssertEqual(response.lockedPackages, [])
        XCTAssertEqual(response.stats, [])
    }

    func testDecodesExplicitNullTopLevelFieldsToEmpty() throws {
        let response = try decode(#"{"lockedPackages": null, "stats": null}"#)
        XCTAssertEqual(response.lockedPackages, [])
        XCTAssertEqual(response.stats, [])
    }

    func testDecodesSparseStatWithMissingOptionalFields() throws {
        let response = try decode(#"{"lockedPackages":["com.x"],"stats":[{"packageName":"com.x","isLimitReached":true}]}"#)
        XCTAssertEqual(response.lockedPackages, ["com.x"])
        XCTAssertEqual(response.stats.count, 1)
        let stat = response.stats[0]
        XCTAssertEqual(stat.packageName, "com.x")
        XCTAssertNil(stat.usageDate)
        XCTAssertEqual(stat.usedSeconds, 0)
        XCTAssertNil(stat.dailyLimitSeconds)
        XCTAssertTrue(stat.isLimitReached)
    }

    func testDecodesFullCamelCasePayload() throws {
        let response = try decode(#"{"lockedPackages":["a"],"stats":[{"packageName":"com.y","usageDate":"2026-07-17","usedSeconds":120,"dailyLimitSeconds":3600,"remainingSeconds":3480,"isLimitReached":false}]}"#)
        let stat = response.stats[0]
        XCTAssertEqual(stat.usageDate, "2026-07-17")
        XCTAssertEqual(stat.usedSeconds, 120)
        XCTAssertEqual(stat.dailyLimitSeconds, 3600)
        XCTAssertEqual(stat.remainingSeconds, 3480)
        XCTAssertFalse(stat.isLimitReached)
    }
}

/// Regression coverage for the `GET /device/lock/state` global-lock parse. The critical invariant:
/// an unrecognized 200 shape resolves to nil (unknown) — NEVER false — so the telemetry layer keeps
/// the last-known lock and can never silently release an active parental lock (fail closed).
final class OilaLockStateParsingTests: XCTestCase {
    func testReadsCommonFlatBooleanKeys() {
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["isLocked": true]), true)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["locked": false]), false)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["globalLock": true]), true)
    }

    func testReadsEnabledKeyUsedByTheSiblingManualLockDto() {
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["enabled": true]), true)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["enabled": false]), false)
    }

    func testReadsStateString() {
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["state": "locked"]), true)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["state": "unlocked"]), false)
    }

    func testReadsNestedGlobalObject() {
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["global": ["enabled": true]]), true)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["global": ["isLocked": false]]), false)
    }

    func testUnrecognizedShapeReturnsNilSoCallerFailsClosed() {
        XCTAssertNil(OilaDeviceClient.parseGlobalLock(from: [:]))
        XCTAssertNil(OilaDeviceClient.parseGlobalLock(from: ["somethingElse": 42]))
        XCTAssertNil(OilaDeviceClient.parseGlobalLock(from: ["state": "weird"]))
    }
}

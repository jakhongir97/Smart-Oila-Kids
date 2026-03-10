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

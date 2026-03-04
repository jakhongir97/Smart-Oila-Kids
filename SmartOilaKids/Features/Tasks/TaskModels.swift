import Foundation

struct AwardsResponse: Decodable, Identifiable {
    var id: Int { awardID }

    let awardID: Int
    let name: String
    let imageURL: String?
    let neededPoints: Int
    let isCompleted: Bool
    let collectedCoins: Int
    let tasks: [TaskItem]

    enum CodingKeys: String, CodingKey {
        case awardID = "award_id"
        case name
        case imageURL = "image_url"
        case neededPoints = "needed_points"
        case isCompleted = "is_completed"
        case collectedCoins = "collected_coins"
        case tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        awardID = container.decodeLossyIntIfPresent(forKey: .awardID) ?? 0
        name = container.decodeLossyStringIfPresent(forKey: .name) ?? ""
        imageURL = container.decodeLossyStringIfPresent(forKey: .imageURL)
        neededPoints = container.decodeLossyIntIfPresent(forKey: .neededPoints) ?? 0
        isCompleted = container.decodeLossyBoolIfPresent(forKey: .isCompleted) ?? false
        collectedCoins = container.decodeLossyIntIfPresent(forKey: .collectedCoins) ?? 0
        tasks = (try? container.decodeIfPresent([TaskItem].self, forKey: .tasks)) ?? []
    }

    init(
        awardID: Int,
        name: String,
        imageURL: String?,
        neededPoints: Int,
        isCompleted: Bool,
        collectedCoins: Int,
        tasks: [TaskItem]
    ) {
        self.awardID = awardID
        self.name = name
        self.imageURL = imageURL
        self.neededPoints = neededPoints
        self.isCompleted = isCompleted
        self.collectedCoins = collectedCoins
        self.tasks = tasks
    }
}

struct TaskItem: Decodable, Identifiable {
    var id: Int { taskID }

    let taskID: Int
    let name: String
    let isFinished: Bool
    let pointsAmount: Int

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case name
        case isFinished = "is_finished"
        case pointsAmount = "points_amount"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = container.decodeLossyIntIfPresent(forKey: .taskID) ?? 0
        name = container.decodeLossyStringIfPresent(forKey: .name) ?? ""
        isFinished = container.decodeLossyBoolIfPresent(forKey: .isFinished) ?? false
        pointsAmount = container.decodeLossyIntIfPresent(forKey: .pointsAmount) ?? 0
    }

    init(
        taskID: Int,
        name: String,
        isFinished: Bool,
        pointsAmount: Int
    ) {
        self.taskID = taskID
        self.name = name
        self.isFinished = isFinished
        self.pointsAmount = pointsAmount
    }
}

struct ChangeTaskStatusResponse: Decodable {
    let taskStatus: Bool
    let awardCompleted: Bool
    let completedAwardID: Int

    enum CodingKeys: String, CodingKey {
        case taskStatus = "task_status"
        case awardCompleted = "award_completed"
        case completedAwardID = "completed_award_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskStatus = container.decodeLossyBoolIfPresent(forKey: .taskStatus) ?? false
        awardCompleted = container.decodeLossyBoolIfPresent(forKey: .awardCompleted) ?? false
        completedAwardID = container.decodeLossyIntIfPresent(forKey: .completedAwardID) ?? 0
    }
}

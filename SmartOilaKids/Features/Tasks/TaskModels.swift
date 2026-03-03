import Foundation

struct AwardsResponse: Codable, Identifiable {
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
}

struct TaskItem: Codable, Identifiable {
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
}

import Foundation

/// The contents of usage.json, as written by `Tokenz --statusline`.
struct UsageFileData: Codable {
    let fiveHour: RateLimitWindow?
    let sevenDay: RateLimitWindow?
    let model: String?
    let updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case model
        case updatedAt = "updated_at"
    }
}

/// A single rate limit window (5-hour or 7-day)
struct RateLimitWindow: Codable {
    let usedPercentage: Double?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

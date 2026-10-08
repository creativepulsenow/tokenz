import Foundation

/// The contents of usage.json, as written by `Tokenz --statusline`.
struct UsageFileData: Codable {
    let fiveHour: RateLimitWindow?
    let sevenDay: RateLimitWindow?
    let model: String?
    let updatedAt: Double?
    /// Any other limits Claude Code reported. Absent in files written by
    /// 1.4.4 and earlier.
    let extra: [NamedRateLimitWindow]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case model
        case updatedAt = "updated_at"
        case extra
    }
}

/// A limit beyond the two fixed ones, with the name to show for it.
struct NamedRateLimitWindow: Codable {
    let name: String?
    let usedPercentage: Double?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case name
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
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

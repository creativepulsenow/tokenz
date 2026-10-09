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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(RateLimitWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(RateLimitWindow.self, forKey: .sevenDay)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt)
        // The extra rows are optional decoration: a malformed list, or one
        // malformed entry in it, must not make the app ignore the two limits
        // that matter.
        extra = (try? container.decodeIfPresent([Lenient<NamedRateLimitWindow>].self, forKey: .extra))?
            .compactMap { $0.value }
    }
}

/// Decodes to nil instead of failing when the value has the wrong shape.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
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

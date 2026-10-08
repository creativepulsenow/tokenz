import Foundation

/// How a percentage is shown, everywhere. Rounded down, so 99.6% never reads
/// as 100% while there is still room.
enum UsageFormat {
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—%" }
        return "\(Int(min(max(value, 0), 100)))%"
    }
}

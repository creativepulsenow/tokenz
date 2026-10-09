import Foundation

/// How a percentage is shown, everywhere. Rounded down, so 99.6% never reads
/// as 100% while there is still room.
enum UsageFormat {
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—%" }
        return "\(Int(min(max(value, 0), 100)))%"
    }
}

/// Names of limits, as shown in the popover.
enum LimitName {
    /// The two rows every plan has.
    static let fiveHour = "Current Session (5hr)"
    static let weekly = "Weekly (7 day)"

    /// Longest name stored or shown for any other limit.
    static let maxScalars = 40

    /// Bidi overrides and line / paragraph separators, which can reorder or
    /// break the text around them, and the Hangul fillers, which Unicode
    /// counts as letters but which draw nothing.
    private static let blocked: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                               0x2066, 0x2067, 0x2068, 0x2069, 0x2028, 0x2029,
                                               0x115F, 0x1160, 0x3164, 0xFFA0]

    /// A name for an extra limit that is safe to show, or nil. The text comes
    /// from Claude Code's JSON or from a file any process running as the user
    /// can write, so: no control or reordering characters, capped in length,
    /// something visible in it, and never one of the built-in rows' labels.
    static func clean(_ raw: String?, maxScalars limit: Int = maxScalars) -> String? {
        guard let raw = raw else { return nil }
        let kept = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !blocked.contains($0.value) }
            .prefix(max(0, limit))
        let name = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        let builtIn = [fiveHour, weekly].map { $0.lowercased() }
        return builtIn.contains(name.lowercased()) ? nil : name
    }
}

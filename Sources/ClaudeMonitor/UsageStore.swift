import Foundation
import Combine

/// Central data model. Holds current usage state, publishes changes to SwiftUI views.
@MainActor
final class UsageStore: ObservableObject {
    @Published var fiveHourPercent: Double? = nil
    @Published var fiveHourResetsAt: Date? = nil
    @Published var sevenDayPercent: Double? = nil
    @Published var sevenDayResetsAt: Date? = nil
    @Published var modelName: String? = nil
    @Published var lastUpdated: Date? = nil
    @Published var isStale: Bool = true  // true when no update in STALE_AFTER seconds

    /// Tight enough that a stale number can't mislead. Status line fires after
    /// every assistant turn, so under active use this should never trip; if it
    /// does, the user has switched contexts and the displayed number is no
    /// longer trustworthy.
    private static let staleAfter: TimeInterval = 90

    private var staleTimer: Timer?

    func update(from data: UsageFileData) {
        // Sanitize at the boundary: the source file can be written by any process
        // with user-level access. Refuse to trust the contents.
        fiveHourPercent = Self.sanitizePercent(data.fiveHour?.usedPercentage)
        fiveHourResetsAt = Self.sanitizeReset(data.fiveHour?.resetsAt)
        sevenDayPercent = Self.sanitizePercent(data.sevenDay?.usedPercentage)
        sevenDayResetsAt = Self.sanitizeReset(data.sevenDay?.resetsAt)
        modelName = Self.sanitizeModel(data.model)
        // Prefer the writer's timestamp over our read time. The two are usually
        // close, but if the writer's timestamp is in the future or absurdly
        // stale, fall back to now so the relative-date string stays sane.
        lastUpdated = Self.sanitizeReset(data.updatedAt) ?? Date()
        isStale = false
        resetStaleTimer()
    }

    /// True once the file has been read at least once.
    var hasReceivedData: Bool { lastUpdated != nil }

    /// True if the file has been read AND it contains usable rate-limit data.
    /// False positives here power the "Pro/Max required" hint in the popover.
    var hasRateLimitData: Bool { fiveHourPercent != nil || sevenDayPercent != nil }

    // MARK: - Sanitizers

    private static func sanitizePercent(_ v: Double?) -> Double? {
        guard let v = v, v.isFinite else { return nil }
        return min(max(v, 0), 100)
    }

    /// Reject reset timestamps further than one year from now in either direction.
    /// Anything outside that range is almost certainly garbage from a misbehaving
    /// writer and would render as nonsensical relative-date strings.
    private static func sanitizeReset(_ v: Double?) -> Date? {
        guard let v = v, v.isFinite else { return nil }
        let now = Date().timeIntervalSince1970
        let oneYear: TimeInterval = 86_400 * 365
        guard abs(v - now) <= oneYear else { return nil }
        return Date(timeIntervalSince1970: v)
    }

    /// Cap length and strip control / bidi-override characters so a malicious
    /// writer can't corrupt the popover layout or visually spoof the model name.
    private static func sanitizeModel(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let capped = String(s.prefix(64))
        let bidiOverrides: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                          0x2066, 0x2067, 0x2068, 0x2069]
        let scrubbed = capped.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) &&
            !bidiOverrides.contains(scalar.value)
        }
        let result = String(String.UnicodeScalarView(scrubbed))
        return result.isEmpty ? nil : result
    }

    private func resetStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: Self.staleAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isStale = true }
        }
    }

    /// Compact text for the menu bar label. Hide the percent when stale so we
    /// never show a confidently-wrong number — the user opens the popover to
    /// see "last updated X ago" and understands why.
    var menuBarText: String {
        guard let pct = fiveHourPercent, !isStale else { return "—%" }
        return "\(Int(pct))%"
    }

    /// Color indicator for the current usage level. Stale data falls back to
    /// `.unknown` (gray dot) so the menu bar visually flags untrustworthy state.
    var usageLevel: UsageLevel {
        guard let pct = fiveHourPercent, !isStale else { return .unknown }
        if pct >= 85 { return .critical }
        if pct >= 60 { return .warning }
        return .normal
    }

    enum UsageLevel {
        case normal, warning, critical, unknown
    }
}

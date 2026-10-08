import Foundation
import UserNotifications

/// Sends macOS notifications when usage crosses thresholds (70%, 85%, 95%).
/// Tracks each window's resets_at to clear fired alerts when the window advances.
/// Persists state to UserDefaults so app restarts don't re-fire alerts.
@MainActor
final class AlertManager {
    private let thresholds: [Int] = [70, 85, 95]
    private let defaults = UserDefaults.standard

    /// Per-metric state: the reset timestamp and which thresholds have fired for that window.
    private struct WindowState: Codable {
        var resetsAt: Double
        var firedThresholds: Set<Int>
    }

    private func key(for metric: String) -> String { "alertState.\(metric)" }

    private func load(_ metric: String) -> WindowState? {
        guard let data = defaults.data(forKey: key(for: metric)) else { return nil }
        return try? JSONDecoder().decode(WindowState.self, from: data)
    }

    private func save(_ state: WindowState, for metric: String) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key(for: metric))
        }
    }

    func checkAndAlert(metric: String, percent: Double, resetsAt: Date?) {
        guard let resetsAt = resetsAt else { return }
        // Defense in depth: caller already clamps, but Int(Double) traps on huge
        // values so guard here too.
        guard percent.isFinite else { return }
        let pct = Int(min(max(percent, 0), 100))
        let resetsAtEpoch = resetsAt.timeIntervalSince1970

        var state = load(metric) ?? WindowState(resetsAt: resetsAtEpoch, firedThresholds: [])

        // A new window has a later reset time. Only that clears the fired
        // thresholds: a writer flipping resets_at back and forth must not be
        // able to replay the alerts. A stored reset time further out than any
        // real window (the longest is 7 days) is junk, so start over from it.
        let isNewWindow = resetsAtEpoch > state.resetsAt + 300
        let storedIsJunk = state.resetsAt > Date().timeIntervalSince1970 + 8 * 86_400
        if isNewWindow || storedIsJunk {
            state = WindowState(resetsAt: resetsAtEpoch, firedThresholds: [])
        }

        // Fire one notification for the highest threshold crossed in this update,
        // and mark all crossed thresholds as fired so we don't backfill on the
        // next tick. Avoids notification storms on first install at 95%.
        let crossed = thresholds.filter { pct >= $0 && !state.firedThresholds.contains($0) }
        if let highest = crossed.max() {
            state.firedThresholds.formUnion(crossed)
            sendNotification(
                title: "Claude Usage Alert",
                body: "\(metric) at \(highest)%+ (\(pct)%). \(resetString(resetsAt))"
            )
        }

        save(state, for: metric)
    }

    private func resetString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "Resets \(f.localizedString(for: date, relativeTo: Date()))"
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Request notification permission. Called on first popover open, not at app launch,
    /// to avoid surprising the user with a permission dialog before they see the UI.
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
}

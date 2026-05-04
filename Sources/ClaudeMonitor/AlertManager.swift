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
        let resetsAtEpoch = resetsAt.timeIntervalSince1970

        var state = load(metric) ?? WindowState(resetsAt: resetsAtEpoch, firedThresholds: [])

        // New window detected (resets_at changed), clear fired thresholds
        if state.resetsAt != resetsAtEpoch {
            state = WindowState(resetsAt: resetsAtEpoch, firedThresholds: [])
        }

        for threshold in thresholds {
            if Int(percent) >= threshold && !state.firedThresholds.contains(threshold) {
                state.firedThresholds.insert(threshold)
                sendNotification(
                    title: "Claude Usage Alert",
                    body: "\(metric) at \(Int(percent))%. \(resetString(resetsAt))"
                )
            }
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

import Foundation
import UserNotifications

/// Sends macOS notifications when usage crosses a threshold (70%, 85%, 95%).
/// State persists in UserDefaults so restarting the app doesn't re-fire alerts.
@MainActor
final class AlertManager {
    private let defaults = UserDefaults.standard

    private func key(for metric: UsageMetric) -> String { "alertState.\(metric.rawValue)" }

    func checkAndAlert(metric: UsageMetric, percent: Double, resetsAt: Date?) {
        guard let resetsAt = resetsAt else { return }
        let saved = defaults.data(forKey: key(for: metric))
            .flatMap { try? JSONDecoder().decode(AlertRules.State.self, from: $0) }
        let (state, fire) = AlertRules.evaluate(
            state: saved, percent: percent,
            resetsAt: resetsAt.timeIntervalSince1970, now: Date().timeIntervalSince1970)

        if let state = state, state != saved, let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key(for: metric))
        }
        if fire != nil {
            sendNotification(
                title: "Claude Usage Alert",
                body: "\(metric.title) usage is at \(UsageFormat.percent(percent)). \(resetString(resetsAt))"
            )
        }
    }

    private func resetString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "Resets \(f.localizedString(for: date, relativeTo: Date()))."
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

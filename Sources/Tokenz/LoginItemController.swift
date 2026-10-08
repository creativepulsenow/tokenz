import Foundation
import ServiceManagement

/// Manages launch-at-login using SMAppService (macOS 13+).
/// The app has to be signed and stay where it is: macOS registers the path.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    /// Why the last change didn't take, shown under the toggle.
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    /// Read the actual system state. Call this on app launch and when the popover opens,
    /// since the user can toggle login items in System Settings directly.
    func refresh() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        refresh()
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            lastError = "Allow Tokenz under System Settings → General → Login Items."
        }
    }
}

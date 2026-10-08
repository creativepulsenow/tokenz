import Foundation
import ServiceManagement

/// Manages launch-at-login using SMAppService (macOS 13+).
/// Requires the app to be ad-hoc signed and located in /Applications.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled: Bool = false

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
        } catch {
            NSLog("Tokenz: Login item update failed: \(error.localizedDescription)")
        }
        refresh()
    }
}

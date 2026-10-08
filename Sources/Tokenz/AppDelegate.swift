import AppKit
import SwiftUI

/// Owns the app lifecycle: UsageStore, FileWatcher, AlertManager, LoginItemController,
/// ClaudeCodeConnection.
/// The SwiftUI App struct delegates to this via @NSApplicationDelegateAdaptor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = UsageStore()
    let alertManager = AlertManager()
    let loginItem = LoginItemController()
    let connection = ClaudeCodeConnection()
    private var fileWatcher: FileWatcher?
    private var tidyTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Housekeeping now, and daily for an app that stays open for months.
        AppPaths.tidy()
        tidyTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in AppPaths.tidy() }

        let watcher = FileWatcher(path: AppPaths.usageFile()) { [weak self] data in
            Task { @MainActor in
                guard let self = self else { return }
                self.store.update(from: data)

                if let pct = self.store.fiveHourPercent {
                    self.alertManager.checkAndAlert(
                        metric: .fiveHour,
                        percent: pct,
                        resetsAt: self.store.fiveHourResetsAt
                    )
                }
                if let pct = self.store.sevenDayPercent {
                    self.alertManager.checkAndAlert(
                        metric: .sevenDay,
                        percent: pct,
                        resetsAt: self.store.sevenDayResetsAt
                    )
                }
            }
        }
        watcher.start()
        self.fileWatcher = watcher
    }

    func applicationWillTerminate(_ notification: Notification) {
        fileWatcher?.stop()
    }
}

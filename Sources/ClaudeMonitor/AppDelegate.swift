import AppKit
import SwiftUI

/// Owns the app lifecycle: UsageStore, FileWatcher, AlertManager, LoginItemController.
/// The SwiftUI App struct delegates to this via @NSApplicationDelegateAdaptor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = UsageStore()
    let alertManager = AlertManager()
    let loginItem = LoginItemController()
    private var fileWatcher: FileWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = Self.dataFilePath()

        let watcher = FileWatcher(path: path) { [weak self] data in
            Task { @MainActor in
                guard let self = self else { return }
                self.store.update(from: data)

                if let pct = self.store.fiveHourPercent {
                    self.alertManager.checkAndAlert(
                        metric: "5-hour session",
                        percent: pct,
                        resetsAt: self.store.fiveHourResetsAt
                    )
                }
                if let pct = self.store.sevenDayPercent {
                    self.alertManager.checkAndAlert(
                        metric: "7-day weekly",
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

    /// Returns the path to the shared usage data file.
    /// Also ensures the directory exists.
    static func dataFilePath() -> String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ClaudeMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.json").path
    }
}

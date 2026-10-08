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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = Self.dataFilePath()
        Self.tidyDataDirectory()

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

    /// Returns the app's data directory, creating it (owner-only) if needed.
    /// Nonisolated: `--statusline` mode calls this without starting the app.
    nonisolated static func dataDirectoryPath() -> String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Tokenz", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.path
    }

    /// Returns the path to the shared usage data file.
    nonisolated static func dataFilePath() -> String {
        (dataDirectoryPath() as NSString).appendingPathComponent("usage.json")
    }

    /// Housekeeping for directories created by earlier versions: make the
    /// directory owner-only, and remove temp files the old bash status line
    /// left behind when Claude Code canceled it mid-write.
    private static func tidyDataDirectory() {
        let fm = FileManager.default
        let dir = dataDirectoryPath()
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let hourAgo = Date().addingTimeInterval(-3600)
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("usage.json.tmp.") {
            let path = (dir as NSString).appendingPathComponent(name)
            if let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               modified < hourAgo {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}

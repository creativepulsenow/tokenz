import Foundation

/// Connects the app to Claude Code by pointing the `statusLine` entry in
/// ~/.claude/settings.json at this app's binary (`--statusline` mode), and
/// undoes it again. Replaces the old install.sh + bash script + jq setup.
@MainActor
final class ClaudeCodeConnection: ObservableObject {
    enum State: Equatable {
        /// Claude Code's status line runs this copy of the app.
        case connected
        /// No status line is configured.
        case notConnected
        /// Ours, but an older setup: the bash script, or the app at another path.
        case needsUpdate
        /// The user has their own status line. Connecting keeps it showing.
        case otherStatusLine
        /// settings.json isn't valid JSON. We won't touch it.
        case settingsUnreadable
        /// Running from the disk image or a quarantine path; the binary's path
        /// wouldn't survive, so it can't go into the settings yet.
        case appNotInstalled
    }

    @Published private(set) var state: State = .notConnected
    /// Outcome of the last Connect / Disconnect, shown in the popover.
    @Published private(set) var message: String?

    private let settingsURL: URL
    private let executablePath: String

    init(settingsURL: URL = ClaudeCodeConnection.defaultSettingsURL,
         executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) {
        self.settingsURL = settingsURL
        self.executablePath = executablePath
        refresh()
    }

    nonisolated static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// The exact `statusLine.command` that means "connected to this copy".
    var ourCommand: String {
        "'" + executablePath.replacingOccurrences(of: "'", with: "'\\''") + "' --statusline"
    }

    /// Re-read the settings. Call on launch and when the popover opens, since
    /// the user (or Claude Code) can edit the file at any time.
    func refresh() {
        if executablePath.contains("/AppTranslocation/") || executablePath.hasPrefix("/Volumes/") {
            state = .appNotInstalled
            return
        }
        let command: String?
        do {
            command = try SettingsEditor.statusLineCommand(in: try? Data(contentsOf: settingsURL))
        } catch {
            state = .settingsUnreadable
            return
        }
        guard let command = command, !command.isEmpty else {
            state = .notConnected
            return
        }
        if command == ourCommand {
            state = .connected
        } else if Self.isOurs(command) {
            state = .needsUpdate
        } else {
            state = .otherStatusLine
        }
    }

    func connect() {
        refresh()
        guard state == .notConnected || state == .needsUpdate || state == .otherStatusLine else { return }
        do {
            let current = try? Data(contentsOf: settingsURL)
            let updated = try SettingsEditor.settingStatusLineCommand(ourCommand, in: current)
            // Remember the user's own status line first, so `--statusline` can
            // keep running it and Disconnect can put it back.
            let previous = state == .otherStatusLine ? try SettingsEditor.statusLineCommand(in: current) : nil
            if let previous = previous { try Self.saveChainedCommand(previous) }
            do {
                try writeSettings(updated)
            } catch {
                if previous != nil { Self.clearChainedCommand() }
                throw error
            }
            message = "Connected. Quit and reopen Claude Code, then send a message."
        } catch {
            message = "Couldn't update Claude Code's settings. Nothing was changed."
        }
        refresh()
    }

    func disconnect() {
        refresh()
        guard state == .connected || state == .needsUpdate else { return }
        do {
            guard let current = try? Data(contentsOf: settingsURL) else { return }
            if let previous = Self.chainedCommand() {
                try writeSettings(SettingsEditor.settingStatusLineCommand(previous, in: current))
                Self.clearChainedCommand()
                message = "Disconnected. Your previous status line is back."
            } else {
                try writeSettings(SettingsEditor.removingStatusLine(in: current))
                message = "Disconnected from Claude Code."
            }
        } catch {
            message = "Couldn't update Claude Code's settings. Nothing was changed."
        }
        refresh()
    }

    /// True for a status line command that is some version of this app,
    /// including the names it shipped under before it was called Tokenz.
    private nonisolated static func isOurs(_ command: String) -> Bool {
        if command.contains("claude-monitor-statusline.sh") { return true }
        guard command.hasSuffix("--statusline") else { return false }
        return command.contains("/Tokenz.app/Contents/MacOS/Tokenz")
            || command.contains("/ClaudeMonitor.app/Contents/MacOS/ClaudeMonitor")
    }

    // MARK: - Writing settings.json

    /// Backs the file up next to itself, then replaces it atomically. Writes
    /// through a symlink to its target so dotfile managers (stow, chezmoi,
    /// yadm) keep working, and keeps the file's permissions.
    private func writeSettings(_ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = settingsURL.resolvingSymlinksInPath()
        var permissions: Any = 0o600
        if fm.fileExists(atPath: target.path) {
            permissions = (try fm.attributesOfItem(atPath: target.path))[.posixPermissions] ?? permissions
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let backup = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.tokenz-backup-\(stamp.string(from: Date()))")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: target, to: backup)
        }
        try data.write(to: target, options: .atomic)
        try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
    }

    // MARK: - The user's previous status line

    private nonisolated static var chainedCommandURL: URL {
        URL(fileURLWithPath: AppDelegate.dataDirectoryPath()).appendingPathComponent("chained-statusline-command")
    }

    /// The status line command the user had before connecting, if any.
    /// Read by `--statusline` on every run, so it stays cheap.
    nonisolated static func chainedCommand() -> String? {
        guard let text = try? String(contentsOf: chainedCommandURL, encoding: .utf8) else { return nil }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never chain to ourselves: that would recurse on every status line run.
        return command.isEmpty || isOurs(command) ? nil : command
    }

    private nonisolated static func saveChainedCommand(_ command: String) throws {
        try Data(command.utf8).write(to: chainedCommandURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chainedCommandURL.path)
    }

    private nonisolated static func clearChainedCommand() {
        try? FileManager.default.removeItem(at: chainedCommandURL)
    }
}

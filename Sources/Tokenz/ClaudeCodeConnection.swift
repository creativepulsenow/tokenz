import Combine
import Foundation

/// Connects the app to Claude Code by pointing the `statusLine` entry in
/// ~/.claude/settings.json at this app's binary (`--statusline` mode), and
/// undoes it again.
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
        /// settings.json can't be edited safely (invalid JSON, duplicate
        /// `statusLine` entries, not a regular file). We won't touch it.
        case settingsUnreadable
        /// Running from the disk image or a quarantine path; the binary's path
        /// wouldn't survive, so it can't go into the settings yet.
        case appNotInstalled
    }

    private enum ConnectionError: Error {
        /// Not a regular file, or far larger than a settings file can be.
        case notASettingsFile
        /// A symlink whose target doesn't exist. Writing would replace the link.
        case danglingSymlink
        /// Claude Code (or the user) rewrote the file while we were editing it.
        case changedUnderneath
        /// The user made the file read-only. That is theirs to undo, not ours.
        case readOnly
    }

    @Published private(set) var state: State = .notConnected
    /// Outcome of the last Connect / Disconnect, shown in the popover until
    /// it is next opened.
    @Published private(set) var message: String?
    /// The user's own status line that `--statusline` also runs, if any.
    /// Shown in the popover so nothing runs that the user can't see.
    @Published private(set) var chained: String?

    private let settingsURL: URL
    private let executablePath: String

    /// A settings file is a few KB. Refuse to load anything that couldn't be one.
    private static let maxSettingsBytes = 5_242_880
    /// How many settings backups to keep.
    private static let backupsToKeep = 5
    private static let backupPrefix = "settings-"

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
    /// - Parameter clearingMessage: pass true when the popover opens, so the
    ///   result of an earlier Connect / Disconnect doesn't linger.
    func refresh(clearingMessage: Bool = false) {
        if clearingMessage { message = nil }
        chained = Self.chainedCommand()
        if executablePath.contains("/AppTranslocation/") || executablePath.hasPrefix("/Volumes/") {
            state = .appNotInstalled
            return
        }
        do {
            state = classify(try SettingsEditor.statusLineCommand(in: try readSettings()))
        } catch {
            state = .settingsUnreadable
        }
    }

    private func classify(_ command: String?) -> State {
        guard let command = command, !command.isEmpty else { return .notConnected }
        // Compare what the command runs, not how it is quoted: a hand-written
        // entry for this same binary is connected too.
        if Self.binaryPath(in: command) == executablePath { return .connected }
        return Self.isOurs(command) ? .needsUpdate : .otherStatusLine
    }

    func connect() {
        do {
            // One read: the state we act on and the bytes we edit must agree.
            let current = try readSettings()
            let previous = try SettingsEditor.statusLineCommand(in: current)
            let before = classify(previous)
            guard state != .appNotInstalled, before != .connected else { refresh(); return }
            let updated = try SettingsEditor.settingStatusLineCommand(ourCommand, in: current)

            switch before {
            case .otherStatusLine:
                // Remember the user's own status line, so `--statusline` can
                // keep running it and Disconnect can put it back.
                if let previous = previous { try Self.saveChainedCommand(previous) }
            case .notConnected:
                // Nothing to chain. Drop any leftover from an earlier
                // connection so an old command can't quietly come back.
                Self.clearChainedCommand()
            default:
                break
            }
            do {
                try writeSettings(updated, replacing: current)
            } catch {
                if before == .otherStatusLine { Self.clearChainedCommand() }
                throw error
            }
            message = "Connected. Send a message in Claude Code to see your usage."
        } catch {
            message = Self.describe(error)
        }
        refresh()
    }

    func disconnect() {
        do {
            guard let current = try readSettings() else { refresh(); return }
            let before = classify(try SettingsEditor.statusLineCommand(in: current))
            guard before == .connected || before == .needsUpdate else { refresh(); return }
            if let previous = Self.chainedCommand() {
                try writeSettings(SettingsEditor.settingStatusLineCommand(previous, in: current), replacing: current)
                Self.clearChainedCommand()
                message = "Disconnected. Your previous status line is back."
            } else {
                try writeSettings(SettingsEditor.removingStatusLine(in: current), replacing: current)
                message = "Disconnected from Claude Code."
            }
        } catch {
            message = Self.describe(error)
        }
        refresh()
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ConnectionError.changedUnderneath:
            return "Claude Code's settings changed while updating. Nothing was changed; try again."
        case ConnectionError.danglingSymlink:
            return "settings.json is a link to a file that doesn't exist. Nothing was changed."
        case ConnectionError.readOnly:
            return "settings.json is read-only. Nothing was changed."
        default:
            return "Couldn't update Claude Code's settings. Nothing was changed."
        }
    }

    // MARK: - Recognizing our own status line

    /// True for a status line command that is exactly some version of this
    /// app and nothing else: the binary (under this name or its old one) with
    /// `--statusline`, or the old bash script on its own. A command that merely
    /// mentions one of them (a wrapper, a pipeline, a comment) is the user's
    /// own, and must be kept and chained, not replaced.
    nonisolated static func isOurs(_ command: String) -> Bool {
        binaryPath(in: command) != nil
    }

    /// If `command` is exactly `<path to the app's binary> --statusline`, the
    /// path.
    nonisolated static func binaryPath(in command: String) -> String? {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let flag = "--statusline"
        guard command.hasSuffix(flag) else { return nil }
        let rest = command.dropLast(flag.count)
        // The flag must be its own word.
        guard let separator = rest.last, separator == " " || separator == "\t",
              let path = singleShellWord(rest.trimmingCharacters(in: .whitespaces)) else { return nil }
        return path.hasSuffix("/Tokenz.app/Contents/MacOS/Tokenz") ? path : nil
    }

    /// If `text` is exactly one plain shell word (bare, single-quoted or
    /// double-quoted, with no expansions or operators), returns what it
    /// denotes. Otherwise nil.
    private nonisolated static func singleShellWord(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            // The only way a quote appears inside is our own `'\''` escape.
            let inner = String(text.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "\u{0}")
            return inner.contains("'") ? nil : inner.replacingOccurrences(of: "\u{0}", with: "'")
        }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            let inner = String(text.dropFirst().dropLast())
            return inner.contains(where: { "\"$`\\".contains($0) }) ? nil : inner
        }
        // `=` would make the shell read the word as a variable assignment.
        let special = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"|;&<>$`\\()#*?[]{}!="))
        return text.unicodeScalars.contains(where: special.contains) ? nil : text
    }

    // MARK: - Reading and writing settings.json

    /// nil if there is no settings file yet. Throws for anything that isn't a
    /// plain file of plausible size, so a FIFO or a huge file can't hang the app.
    private func readSettings() throws -> Data? {
        let fm = FileManager.default
        // `fileExists` follows symlinks, so this is also false for a dangling link.
        guard fm.fileExists(atPath: settingsURL.path) else {
            // Missing is fine; a link pointing nowhere is not something to edit.
            if (try? fm.destinationOfSymbolicLink(atPath: settingsURL.path)) != nil {
                throw ConnectionError.danglingSymlink
            }
            return nil
        }
        let target = settingsURL.resolvingSymlinksInPath()
        guard let info = try? fm.attributesOfItem(atPath: target.path),
              info[.type] as? FileAttributeType == .typeRegular,
              let size = info[.size] as? Int, size <= Self.maxSettingsBytes else {
            throw ConnectionError.notASettingsFile
        }
        return try Data(contentsOf: target)
    }

    /// Backs the file up, then replaces it in one step. Writes through a
    /// symlink to its target so dotfile managers (stow, chezmoi, yadm) keep
    /// working, and keeps the file's permissions. Refuses if the file no
    /// longer holds `original`, which makes losing a concurrent edit very
    /// unlikely (the check and the replace are not one atomic operation).
    private func writeSettings(_ data: Data, replacing original: Data?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try readSettings() == original else { throw ConnectionError.changedUnderneath }

        let target = settingsURL.resolvingSymlinksInPath()
        var permissions: mode_t = 0o600
        if let original = original {
            guard fm.isWritableFile(atPath: target.path) else { throw ConnectionError.readOnly }
            if let mode = (try fm.attributesOfItem(atPath: target.path))[.posixPermissions] as? NSNumber {
                permissions = mode_t(mode.uint16Value) & 0o777
            }
            try backUp(original)
        }
        guard AppPaths.writeAtomically(data, to: target.path, permissions: permissions) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Saves a copy of the settings file and prunes old copies. Backups are
    /// full copies and can hold whatever the user keeps in settings.json
    /// (`env` values, for instance), so they live in the app's own owner-only
    /// directory, not next to a file that may sit in a dotfiles repo. They
    /// are never overwritten, and only the newest few are kept.
    private func backUp(_ contents: Data) throws {
        let fm = FileManager.default
        let directory = AppPaths.settingsBackupsDirectory()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = Self.backupPrefix + stamp.string(from: Date())
        var name = base + ".json"
        var counter = 2
        while fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name)) {
            name = "\(base)-\(counter).json"
            counter += 1
        }
        guard AppPaths.writeAtomically(contents, to: (directory as NSString).appendingPathComponent(name)) else {
            throw CocoaError(.fileWriteUnknown)
        }

        // Names sort by time, so the oldest come first. Only ever delete
        // plain files that carry our exact naming.
        let pattern = "^settings-[0-9]{8}-[0-9]{6}(-[0-9]+)?\\.json$"
        let ours = ((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .sorted()
        for old in ours.dropLast(Self.backupsToKeep) {
            let path = (directory as NSString).appendingPathComponent(old)
            if (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    // MARK: - The user's previous status line

    /// The status line command the user had before connecting, if any.
    /// Read by `--statusline` on every run, so it stays cheap.
    nonisolated static func chainedCommand() -> String? {
        guard let data = AppPaths.readSmallFile(AppPaths.chainedCommandFile()) else { return nil }
        let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Never chain to ourselves. (`--statusline` also guards against
        // indirect loops with an environment marker.)
        return command.isEmpty || isOurs(command) ? nil : command
    }

    private nonisolated static func saveChainedCommand(_ command: String) throws {
        guard AppPaths.writeAtomically(Data(command.utf8), to: AppPaths.chainedCommandFile()) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private nonisolated static func clearChainedCommand() {
        try? FileManager.default.removeItem(atPath: AppPaths.chainedCommandFile())
    }

    /// Stops running the user's previous status line alongside Tokenz.
    func removeChainedCommand() {
        Self.clearChainedCommand()
        refresh()
    }
}

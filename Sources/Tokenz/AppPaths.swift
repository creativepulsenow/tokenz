import Foundation

/// Where the app keeps its files, and the two file operations every part of
/// it shares. Foundation only: `--statusline` mode uses this without starting
/// the app.
enum AppPaths {
    /// usage.json is a couple hundred bytes. Refuse anything that couldn't be it.
    static let maxUsageFileBytes = 65_536

    /// The app's data directory, created owner-only if needed.
    static func dataDirectory() -> String {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return ensureDirectory(support.appendingPathComponent("Tokenz", isDirectory: true).path)
    }

    /// The usage numbers `--statusline` writes and the menu bar app reads.
    static func usageFile() -> String {
        (dataDirectory() as NSString).appendingPathComponent("usage.json")
    }

    /// One small record per Claude Code session, written by `--statusline`.
    static func sessionsDirectory() -> String {
        ensureDirectory((dataDirectory() as NSString).appendingPathComponent("sessions"))
    }

    /// Copies of settings.json taken before each edit.
    static func settingsBackupsDirectory() -> String {
        ensureDirectory((dataDirectory() as NSString).appendingPathComponent("settings-backups"))
    }

    /// The status line command the user had before connecting, if any.
    static func chainedCommandFile() -> String {
        (dataDirectory() as NSString).appendingPathComponent("chained-statusline-command")
    }

    private static func ensureDirectory(_ path: String) -> String {
        try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }

    /// Reads a small regular file, or returns nil. Any process running as the
    /// user can write to these paths, so: open without following a symlink,
    /// then check the open descriptor (not the path, which could be swapped
    /// between a check and the read). O_NONBLOCK keeps a FIFO from hanging
    /// the open.
    static func readSmallFile(_ path: String, maxBytes: Int = maxUsageFileBytes) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maxBytes else { return nil }
        return try? handle.read(upToCount: maxBytes)
    }

    /// Replaces `path` with `data` in one step, so a reader never sees half a
    /// file. The temp file is created with its final permissions (it is never
    /// more readable than the result) and removed again if anything fails.
    @discardableResult
    static func writeAtomically(_ data: Data, to path: String, permissions: mode_t = 0o600) -> Bool {
        let temp = path + temporarySuffix + String(getpid())
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
        guard fd >= 0 else { return false }
        // `open` applies the umask; set the mode exactly.
        fchmod(fd, permissions)
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        close(fd)
        guard written, rename(temp, path) == 0 else {
            unlink(temp)
            return false
        }
        return true
    }

    /// Marks our temp files, so ones orphaned by a killed run can be swept up.
    static let temporarySuffix = ".tokenz-tmp."

    /// Removes temp files a killed `--statusline` run left behind, and records
    /// of Claude Code sessions that ended long ago.
    static func tidy(now: Date = Date()) {
        let fm = FileManager.default
        func removeFiles(in directory: String, olderThan age: TimeInterval, where matches: (String) -> Bool) {
            for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] where matches(name) {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let info = try? fm.attributesOfItem(atPath: path),
                      info[.type] as? FileAttributeType == .typeRegular,
                      let modified = info[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > age else { continue }
                try? fm.removeItem(atPath: path)
            }
        }
        let hour: TimeInterval = 3600
        let isTemp: (String) -> Bool = { $0.contains(temporarySuffix) }
        removeFiles(in: dataDirectory(), olderThan: hour, where: isTemp)
        removeFiles(in: sessionsDirectory(), olderThan: hour, where: isTemp)
        removeFiles(in: sessionsDirectory(), olderThan: 14 * 24 * hour, where: { _ in true })
    }
}

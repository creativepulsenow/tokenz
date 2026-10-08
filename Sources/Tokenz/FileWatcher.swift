import Foundation

/// Watches usage.json with a file-system dispatch source (kqueue), decodes it
/// on change and hands the result to `onChange`.
///
/// Events are best-effort. `--statusline` replaces the file with a rename, so
/// the watched file is gone after every update and the source has to be
/// reattached to the new one. To stay correct if an event is missed, or while
/// the file doesn't exist yet, the file is also checked on a slow timer.
final class FileWatcher {
    /// How often the safety-net check runs.
    private static let pollInterval: TimeInterval = 10

    private let filePath: String
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var lastModified: Date?
    private let onChange: (UsageFileData) -> Void
    private let queue = DispatchQueue(label: "Tokenz.FileWatcher", qos: .utility)

    init(path: String, onChange: @escaping (UsageFileData) -> Void) {
        self.filePath = path
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            self?.attach()
            self?.startPolling()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
        }
    }

    /// Starts watching the file that is at the path right now. If there is
    /// none, the poll timer tries again.
    private func attach() {
        source?.cancel()
        source = nil

        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self = self, let src = src else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                // Replaced by a new file: watch that one. It is already in place.
                self.attach()
            } else {
                self.readFile()
            }
        }
        // The only place the descriptor is closed.
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()

        // Read after attaching, so a write landing in between still raises an event.
        readFile()
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        pollTimer = timer
        timer.resume()
    }

    private func poll() {
        guard source != nil else {
            // Not watching anything yet (no file at launch): try now.
            attach()
            return
        }
        // Re-read only if the file changed since our last read.
        guard let mtime = modificationDate(), mtime != lastModified else { return }
        attach()
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: filePath))?[.modificationDate] as? Date
    }

    private func readFile() {
        guard let data = AppPaths.readSmallFile(filePath), !data.isEmpty,
              let parsed = try? JSONDecoder().decode(UsageFileData.self, from: data) else {
            return
        }
        lastModified = modificationDate()
        onChange(parsed)
    }
}

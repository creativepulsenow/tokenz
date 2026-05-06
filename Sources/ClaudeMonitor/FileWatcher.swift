import Foundation

/// Watches ~/Library/Application Support/ClaudeMonitor/usage.json using DispatchSource (FSEvents).
/// Parses the file on change and calls the onChange callback with the decoded data.
///
/// Reliability strategy: events are best-effort. The status line writes via atomic
/// `mv` (unlinks the old inode, creates a new one), so the fd-based watcher has to
/// detect `.delete`, cancel, and reattach. Events can be missed during the reattach
/// window, or if `open()` races with `mv`. To make the menu bar resilient to dropped
/// events, we also poll the file at a steady cadence as a safety net.
final class FileWatcher {
    private let filePath: String
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var lastModified: Date?
    private let onChange: (UsageFileData) -> Void
    private let queue = DispatchQueue(label: "ClaudeMonitor.FileWatcher", qos: .utility)

    init(path: String, onChange: @escaping (UsageFileData) -> Void) {
        self.filePath = path
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            self?.startInternal()
            self?.startPolling()
        }
    }

    private func startInternal() {
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet, poll until it appears (and let the safety
            // poller pick it up too).
            readFile()
            scheduleRetry()
            return
        }
        fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )

        src.setEventHandler { [weak self, weak src] in
            guard let self = self, let src = src else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was replaced (atomic write pattern: tmp + mv), re-watch
                self.restart()
            } else {
                self.readFile()
            }
        }

        // SOLE owner of fd cleanup. Do not close fd anywhere else.
        src.setCancelHandler { [fd] in
            close(fd)
        }

        self.source = src
        src.resume()

        // Read AFTER attaching the source. Reading first leaves a window where a
        // write could land between read and open, and we'd miss it until the next
        // write. Reading after means any write that happens between open and
        // readFile will fire an event we'll catch.
        readFile()
    }

    /// Periodic safety-net poll. Catches any updates that the event-based
    /// watcher missed (e.g., the open/readFile race, or events dropped under
    /// system load). Cheap: stat + maybe-read.
    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        pollTimer = timer
        timer.resume()
    }

    private func pollOnce() {
        // Only re-read if the file's mtime has actually changed since our last
        // read. Avoids redundant decode work and onChange churn.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let mtime = attrs[.modificationDate] as? Date else {
            return
        }
        if let last = lastModified, last == mtime {
            return
        }
        readFile()
    }

    private func readFile() {
        guard let data = FileManager.default.contents(atPath: filePath),
              !data.isEmpty,
              let parsed = try? JSONDecoder().decode(UsageFileData.self, from: data) else {
            return
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
           let mtime = attrs[.modificationDate] as? Date {
            lastModified = mtime
        }
        onChange(parsed)
    }

    private func restart() {
        source?.cancel()    // triggers setCancelHandler -> close(fd)
        source = nil
        fileDescriptor = -1 // mark as released; do NOT close here
        scheduleRetry()
    }

    private func scheduleRetry() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startInternal()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            self?.fileDescriptor = -1
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
        }
    }
}

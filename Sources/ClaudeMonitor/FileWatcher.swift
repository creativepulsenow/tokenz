import Foundation

/// Watches ~/Library/Application Support/ClaudeMonitor/usage.json using DispatchSource (FSEvents).
/// Parses the file on change and calls the onChange callback with the decoded data.
final class FileWatcher {
    private let filePath: String
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let onChange: (UsageFileData) -> Void
    private let queue = DispatchQueue(label: "ClaudeMonitor.FileWatcher", qos: .utility)

    init(path: String, onChange: @escaping (UsageFileData) -> Void) {
        self.filePath = path
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in self?.startInternal() }
    }

    private func startInternal() {
        // Initial read if file already exists
        readFile()

        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet, poll until it appears
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
    }

    private func readFile() {
        guard let data = FileManager.default.contents(atPath: filePath),
              !data.isEmpty,
              let parsed = try? JSONDecoder().decode(UsageFileData.self, from: data) else {
            return
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
        }
    }
}

import Foundation

/// PID of the chained status line while it runs, for the signal handler below.
/// A plain global because a C signal handler can't capture anything.
private var chainedChildPID: pid_t = 0

/// The `--statusline` mode of the app binary. Claude Code runs it as its status
/// line command and pipes session JSON on stdin; we project the rate-limit
/// fields into usage.json for the menu bar app and print one line for Claude
/// Code to display.
///
/// Runs and exits without starting the app, so it must stay fast and must not
/// touch AppKit or SwiftUI.
enum StatusLineCommand {
    /// Claude Code's session JSON is a few KB. Anything far past that isn't it.
    private static let maxInputBytes = 1_048_576

    /// Set in the environment of a chained status line. If we see it on
    /// startup, some chain of commands led back to us, and chaining again
    /// would recurse on every status line run.
    private static let chainedMarker = "TOKENZ_CHAINED"

    /// One rate-limit window as reported by Claude Code.
    private struct Window {
        var percent: Double
        var resetsAt: Double?

        var json: [String: Any] {
            ["used_percentage": percent, "resets_at": resetsAt ?? NSNull()]
        }
    }

    /// Whether this run carries usage numbers newer than the session's last run.
    ///
    /// Every Claude Code session keeps the numbers from its own last API reply
    /// and re-runs the status line for reasons that have nothing to do with
    /// usage (cache expiry, a window resetting, a mode change). An idle session
    /// would otherwise overwrite the current number with an hours-old one.
    private enum Freshness {
        /// The session has had an API reply since its last run.
        case fresh
        /// Nothing new since this session's last run.
        case stale
        /// First time we see this session, or it gave us nothing to go on.
        case unknown
    }

    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()

        var statusText = "..."
        if input.count <= maxInputBytes,
           let session = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] {
            let limits = session["rate_limits"] as? [String: Any]
            let shown = store(
                fiveHour: window(limits?["five_hour"]),
                sevenDay: window(limits?["seven_day"]),
                model: (session["model"] as? [String: Any])?["display_name"] as? String,
                freshness: freshness(of: session))

            // Print what the menu bar shows, not this session's own (possibly
            // older) numbers. Percentages are clamped, so Int() can't trap.
            let parts = [("5h", shown.fiveHour), ("7d", shown.sevenDay)].compactMap { label, w -> String? in
                w.map { "\(label): \(Int($0.percent.rounded()))%" }
            }
            if !parts.isEmpty { statusText = parts.joined(separator: " | ") }
        }

        // If the user had their own status line before connecting, keep showing
        // it: hand it the same stdin and let its output through instead of ours.
        if ProcessInfo.processInfo.environment[chainedMarker] == nil,
           let previous = ClaudeCodeConnection.chainedCommand(),
           runChained(previous, input: input) {
            return
        }
        print(statusText)
    }

    // MARK: - Deciding what to keep

    /// Merges this run's reading into usage.json and returns the windows that
    /// are current afterward.
    private static func store(fiveHour: Window?, sevenDay: Window?, model: String?,
                              freshness: Freshness) -> (fiveHour: Window?, sevenDay: Window?) {
        let stored = (try? Data(contentsOf: URL(fileURLWithPath: AppDelegate.dataFilePath())))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let now = Date().timeIntervalSince1970
        // A stored window still counts until its reset time passes.
        func live(_ key: String) -> Window? {
            guard let w = window(stored?[key]), let reset = w.resetsAt, reset > now else { return nil }
            return w
        }
        let storedFive = live("five_hour"), storedSeven = live("seven_day")
        let kept = (fiveHour: storedFive, sevenDay: storedSeven)

        if stored != nil {
            switch freshness {
            case .stale:
                return kept
            case .unknown:
                // Can't tell how old this reading is, so at least never let it
                // take usage backward inside a window.
                if isOlder(fiveHour, than: storedFive) || isOlder(sevenDay, than: storedSeven) { return kept }
            case .fresh:
                break
            }
            // No limits in this run (a session on an API key, say) is not a
            // reason to wipe limits another session reported.
            if fiveHour == nil, sevenDay == nil, storedFive != nil || storedSeven != nil { return kept }
        }

        let merged = (fiveHour: fiveHour ?? storedFive, sevenDay: sevenDay ?? storedSeven)
        // Always write when nothing is stored yet, even without limits, so the
        // app can tell "no data yet" from "connected, but no limits reported".
        write([
            "five_hour": merged.fiveHour?.json ?? NSNull(),
            "seven_day": merged.sevenDay?.json ?? NSNull(),
            "model": model ?? stored?["model"] ?? NSNull(),
            "updated_at": now,
        ])
        return merged
    }

    /// True if `incoming` describes an earlier state than `stored`: the same
    /// window with less used, or a window that ended before the stored one.
    private static func isOlder(_ incoming: Window?, than stored: Window?) -> Bool {
        guard let incoming = incoming, let stored = stored,
              let incomingReset = incoming.resetsAt, let storedReset = stored.resetsAt else { return false }
        if abs(incomingReset - storedReset) < 60 { return incoming.percent < stored.percent }
        return incomingReset < storedReset
    }

    /// Compares the session's accumulated API time with what we recorded on
    /// its previous run. It only grows when the session gets an API reply,
    /// which is also the only time its usage numbers are refreshed.
    private static func freshness(of session: [String: Any]) -> Freshness {
        guard let id = session["session_id"] as? String, !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ sessionIDCharacters.contains($0) }),
              let apiTime = number((session["cost"] as? [String: Any])?["total_api_duration_ms"]) else {
            return .unknown
        }
        // One small file per session: sessions run concurrently, and a shared
        // file would lose updates.
        let directory = URL(fileURLWithPath: AppDelegate.sessionsDirectoryPath())
        let file = directory.appendingPathComponent(id)
        let recorded = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Double($0) }
        if recorded == apiTime { return .stale }
        try? Data(String(apiTime).utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // First sighting: the reading could be seconds or hours old.
        return recorded == nil ? .unknown : .fresh
    }

    private static let sessionIDCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// Reads one window, from Claude Code's JSON or from usage.json. Only a
    /// window with a sane percentage counts.
    private static func window(_ raw: Any?) -> Window? {
        guard let raw = raw as? [String: Any], let percent = number(raw["used_percentage"]) else { return nil }
        return Window(percent: min(max(percent, 0), 100), resetsAt: number(raw["resets_at"]))
    }

    private static func number(_ v: Any?) -> Double? {
        // JSON booleans also bridge to NSNumber; they aren't a percentage.
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// Atomic write (temp file + rename) so the app never reads a half-written
    /// file. Owner-only: the numbers are nobody else's business on a shared Mac.
    private static func write(_ object: [String: Any]) {
        let file = URL(fileURLWithPath: AppDelegate.dataFilePath())
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Returns false if the command couldn't be started, so the caller can fall
    /// back to printing our own line.
    private static func runChained(_ command: String, input: Data) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment[chainedMarker] = "1"
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        // stdout and stderr are inherited, so Claude Code sees the output directly.
        do { try process.run() } catch { return false }

        // Claude Code cancels a status line that is still running when the next
        // update arrives. Take the chained command down with us, or slow ones
        // would pile up across turns.
        chainedChildPID = process.processIdentifier
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { received in
                if chainedChildPID > 0 { kill(chainedChildPID, SIGTERM) }
                _exit(128 + received)
            }
        }
        // The reader may exit without draining stdin; that must not kill us.
        signal(SIGPIPE, SIG_IGN)
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return true
    }
}

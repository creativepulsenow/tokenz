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

    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()

        var statusText = "..."
        if input.count <= maxInputBytes,
           let session = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] {
            let limits = session["rate_limits"] as? [String: Any]
            let fiveHour = window(limits?["five_hour"])
            let sevenDay = window(limits?["seven_day"])
            let model = (session["model"] as? [String: Any])?["display_name"] as? String

            // Always write, even when rate_limits is absent, so the app can tell
            // "no data yet" from "connected, but this plan reports no limits".
            write([
                "five_hour": fiveHour ?? NSNull(),
                "seven_day": sevenDay ?? NSNull(),
                "model": model ?? NSNull(),
                "updated_at": Date().timeIntervalSince1970,
            ])

            let parts = [("5h", fiveHour), ("7d", sevenDay)].compactMap { label, w -> String? in
                // Already clamped to 0...100 by `window`, so Int() can't trap.
                guard let pct = w?["used_percentage"] as? Double else { return nil }
                return "\(label): \(Int(pct.rounded()))%"
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

    /// Keeps only the two fields we use, and only when they are sane numbers.
    private static func window(_ raw: Any?) -> [String: Any]? {
        guard let raw = raw as? [String: Any] else { return nil }
        let percent = number(raw["used_percentage"]).map { min(max($0, 0), 100) }
        return [
            "used_percentage": percent ?? NSNull(),
            "resets_at": number(raw["resets_at"]) ?? NSNull(),
        ]
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

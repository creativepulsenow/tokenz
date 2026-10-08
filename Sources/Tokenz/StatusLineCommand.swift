import Foundation

/// Process group of the chained status line while it runs, for the signal
/// handler below. A plain global because a C signal handler can't capture.
private var chainedProcessGroup: pid_t = 0

/// The `--statusline` mode of the app binary. Claude Code runs it as its status
/// line command and pipes session JSON on stdin; we fold the rate-limit fields
/// into usage.json for the menu bar app and print one line for Claude Code to
/// display.
///
/// Runs and exits without starting the app, so it must stay fast and use
/// Foundation only.
enum StatusLineCommand {
    /// Claude Code's session JSON is a few KB. Anything far past that isn't it.
    private static let maxInputBytes = 1_048_576

    /// Longest model name we store. The app caps it again when it reads.
    private static let maxModelScalars = 64

    /// Set in the environment of a chained status line. If we see it on
    /// startup, some chain of commands led back to us, and chaining again
    /// would recurse on every status line run.
    private static let chainedMarker = "TOKENZ_CHAINED"

    static func run() {
        guard let input = readInput() else {
            // Not session JSON, and too large to hand on.
            print("...")
            return
        }

        var statusText = "..."
        if let session = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] {
            let limits = session["rate_limits"] as? [String: Any]
            let model = ((session["model"] as? [String: Any])?["display_name"] as? String)
                .map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(maxModelScalars))) }
            let incoming = UsageMerge.Reading(
                fiveHour: window(limits?["five_hour"]),
                sevenDay: window(limits?["seven_day"]),
                model: model,
                extra: extraWindows(limits))

            let record = SessionRecord(session: session)
            let now = Date().timeIntervalSince1970
            let outcome = UsageMerge.merge(
                stored: storedReading(), incoming: incoming, freshness: record.freshness, now: now)
            if outcome.shouldWrite { write(outcome.current, updatedAt: now) }
            // Only now that the reading is safely stored (or deliberately
            // dropped) do we note that we've seen it. If Claude Code cancels
            // this run earlier, the re-run must still count as news.
            record.save()
            // After the record, so a canceled run can lose an increase but
            // never count one twice.
            if let model = model, let increase = record.increase,
               let week = outcome.current.sevenDay?.resetsAt {
                addModelUsage(model: model, cost: increase.cost, time: increase.time, weekResetsAt: week)
            }

            // Print what the menu bar shows, not this session's own (possibly
            // older) numbers.
            let parts = [("5h", outcome.current.fiveHour), ("7d", outcome.current.sevenDay)]
                .compactMap { label, w in w.map { "\(label): \(UsageFormat.percent($0.percent))" } }
            if !parts.isEmpty { statusText = parts.joined(separator: " | ") }
        }

        // If the user had their own status line before connecting, keep showing
        // it: hand it the same stdin and let its output through instead of ours.
        if ProcessInfo.processInfo.environment[chainedMarker] == nil,
           let previous = ClaudeCodeConnection.chainedCommand(),
           let status = runChained(previous, input: input) {
            exit(status)
        }
        print(statusText)
    }

    /// All of stdin, or nil if it is larger than any session JSON could be.
    private static func readInput() -> Data? {
        var input = Data()
        let stdin = FileHandle.standardInput
        while let chunk = try? stdin.read(upToCount: 65_536), !chunk.isEmpty {
            input.append(chunk)
            if input.count > maxInputBytes { return nil }
        }
        return input
    }

    // MARK: - Reading and writing usage.json

    /// A window from Claude Code's JSON or from usage.json. Only one with a
    /// usable percentage counts; the percentage is clamped to 0...100.
    private static func window(_ raw: Any?) -> UsageMerge.Window? {
        guard let raw = raw as? [String: Any], let percent = number(raw["used_percentage"]) else { return nil }
        return UsageMerge.Window(percent: min(max(percent, 0), 100), resetsAt: number(raw["resets_at"]))
    }

    private static func number(_ v: Any?) -> Double? {
        // JSON booleans also bridge to NSNumber; they aren't a percentage.
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// The limits Claude Code never passes to every plan, and so has no fixed
    /// row in the app: handled by `extraWindows`.
    private static let fixedLimitKeys: Set<String> = ["five_hour", "seven_day", "spend_limit", "model_scoped"]
    private static let maxExtraWindows = 8
    private static let maxLimitNameScalars = 40

    /// Any other limit in `rate_limits` that looks like a window. Today
    /// Claude Code sends none; if it starts to (per-model weekly limits, for
    /// instance), they show up in the app without a new release.
    private static func extraWindows(_ limits: [String: Any]?) -> [UsageMerge.NamedWindow] {
        guard let limits = limits else { return [] }
        var found: [UsageMerge.NamedWindow] = []
        for key in limits.keys.sorted() where !fixedLimitKeys.contains(key) {
            if let w = window(limits[key]), let name = limitName(forKey: key) {
                found.append(UsageMerge.NamedWindow(name: name, window: w))
            }
        }
        // Limits scoped to a model arrive as a list with their own labels.
        for entry in (limits["model_scoped"] as? [Any]) ?? [] {
            if let entry = entry as? [String: Any], let w = window(entry),
               let name = cleanLimitName(entry["display_name"] as? String) {
                found.append(UsageMerge.NamedWindow(name: name, window: w))
            }
        }
        return Array(found.prefix(maxExtraWindows))
    }

    /// `seven_day_opus` becomes "Opus (weekly)", `five_hour_x` "X (5hr)".
    private static func limitName(forKey key: String) -> String? {
        for (prefix, suffix) in [("seven_day_", " (weekly)"), ("five_hour_", " (5hr)")] where key.hasPrefix(prefix) {
            return cleanLimitName(key.dropFirst(prefix.count).replacingOccurrences(of: "_", with: " ").capitalized)
                .map { $0 + suffix }
        }
        return cleanLimitName(key.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    private static func cleanLimitName(_ name: String?) -> String? {
        guard let name = name else { return nil }
        let scalars = name.unicodeScalars.prefix(maxLimitNameScalars)
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func storedReading() -> UsageMerge.Reading? {
        guard let data = AppPaths.readSmallFile(AppPaths.usageFile()),
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let extra = ((stored["extra"] as? [Any]) ?? []).compactMap { entry -> UsageMerge.NamedWindow? in
            guard let entry = entry as? [String: Any], let w = window(entry),
                  let name = cleanLimitName(entry["name"] as? String) else { return nil }
            return UsageMerge.NamedWindow(name: name, window: w)
        }
        return UsageMerge.Reading(
            fiveHour: window(stored["five_hour"]),
            sevenDay: window(stored["seven_day"]),
            model: stored["model"] as? String,
            extra: Array(extra.prefix(maxExtraWindows)))
    }

    private static func write(_ reading: UsageMerge.Reading, updatedAt: Double) {
        func json(_ w: UsageMerge.Window) -> [String: Any] {
            ["used_percentage": w.percent, "resets_at": w.resetsAt ?? NSNull()]
        }
        let object: [String: Any] = [
            "five_hour": reading.fiveHour.map(json) ?? NSNull(),
            "seven_day": reading.sevenDay.map(json) ?? NSNull(),
            "extra": reading.extra.map { json($0.window).merging(["name": $0.name]) { a, _ in a } },
            "model": reading.model ?? NSNull(),
            "updated_at": updatedAt,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        AppPaths.writeAtomically(data, to: AppPaths.usageFile())
    }

    // MARK: - This week by model

    /// Adds one session's increase to this week's per-model totals. Sessions
    /// run concurrently, so the read-change-write happens under a file lock;
    /// if the lock can't be had quickly, the increase is dropped rather than
    /// holding up Claude Code's status line.
    private static func addModelUsage(model: String, cost: Double, time: Double, weekResetsAt: Double) {
        let path = AppPaths.modelUsageFile()
        let lock = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { return }
        defer { close(lock) }   // also releases the lock
        var attempts = 0
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            attempts += 1
            if attempts > 20 { return }
            usleep(5_000)
        }
        var usage = AppPaths.readSmallFile(path)
            .flatMap { try? JSONDecoder().decode(ModelUsage.self, from: $0) }
            ?? ModelUsage(weekResetsAt: weekResetsAt)
        usage.add(model: model, cost: cost, time: time, weekResetsAt: weekResetsAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(usage) { AppPaths.writeAtomically(data, to: path) }
    }

    // MARK: - Per-session freshness

    /// What we remember about one Claude Code session between runs: its
    /// accumulated API time and cost. API time only grows when the session
    /// gets an API reply, which is also the only time its usage numbers are
    /// refreshed.
    private struct SessionRecord {
        private let file: String?
        private let apiTime: Double?
        private let cost: Double?
        let freshness: UsageMerge.Freshness
        /// How much the session's cost and API time grew since its last run.
        /// Nil on first sighting, when there is nothing to compare against.
        let increase: (cost: Double, time: Double)?

        private static let idCharacters = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        private static let maxIDLength = 128

        init(session: [String: Any]) {
            // The id becomes a file name, so only plain characters are accepted.
            guard let id = session["session_id"] as? String, !id.isEmpty, id.count <= Self.maxIDLength,
                  id.unicodeScalars.allSatisfy({ Self.idCharacters.contains($0) }),
                  let apiTime = number((session["cost"] as? [String: Any])?["total_api_duration_ms"]) else {
                file = nil
                apiTime = nil
                cost = nil
                freshness = .unknown
                increase = nil
                return
            }
            let cost = number((session["cost"] as? [String: Any])?["total_cost_usd"])
            // One small file per session: sessions run concurrently, and a
            // shared file would lose updates. It holds the API time, then the
            // cost if Claude Code reported one.
            let file = (AppPaths.sessionsDirectory() as NSString).appendingPathComponent(id)
            let recorded = (AppPaths.readSmallFile(file, maxBytes: 64).map { String(decoding: $0, as: UTF8.self) } ?? "")
                .split(separator: " ").map { Double($0) }
            let recordedTime = recorded.first ?? nil
            let recordedCost = recorded.count > 1 ? recorded[1] : nil
            self.file = file
            self.apiTime = apiTime
            self.cost = cost
            if let recordedTime = recordedTime {
                freshness = recordedTime == apiTime ? .stale : .fresh
                // A counter that went backward means the session restarted;
                // there is no telling how much of the new total is new.
                if apiTime > recordedTime {
                    let costIncrease = cost.flatMap { now in recordedCost.map { max(0, now - $0) } } ?? 0
                    increase = (cost: costIncrease, time: apiTime - recordedTime)
                } else {
                    increase = nil
                }
            } else {
                // First sighting: the reading could be seconds or hours old.
                freshness = .unknown
                increase = nil
            }
        }

        func save() {
            guard let file = file, let apiTime = apiTime, freshness != .stale else { return }
            let text = cost.map { "\(apiTime) \($0)" } ?? "\(apiTime)"
            AppPaths.writeAtomically(Data(text.utf8), to: file)
        }
    }

    // MARK: - The user's previous status line

    /// Runs the chained command with `input` on its stdin and its output going
    /// straight to Claude Code. Returns its exit status, or nil if it couldn't
    /// be run (so the caller prints our own line instead of a blank one).
    private static func runChained(_ command: String, input: Data) -> Int32? {
        var pipeEnds: [Int32] = [0, 0]
        guard pipe(&pipeEnds) == 0 else { return nil }
        let (readEnd, writeEnd) = (pipeEnds[0], pipeEnds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        // Its own process group, so a whole pipeline can be signaled at once.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var environment = ProcessInfo.processInfo.environment
        environment[chainedMarker] = "1"
        // Spelled out step by step: older compilers can't infer these in one expression.
        let arguments: [String] = ["sh", "-c", command]
        let variables: [String] = environment.map { "\($0.key)=\($0.value)" }
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = variables.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        // Claude Code cancels a status line that is still running when the
        // next update arrives. Take the chained command's process group down
        // with us, or slow commands would pile up across turns. Installed
        // before the spawn so there is no gap; a signal we were started with
        // ignored stays ignored.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            let previous = signal(sig) { received in
                if chainedProcessGroup > 0 { kill(-chainedProcessGroup, SIGTERM) }
                _exit(128 + received)
            }
            if unsafeBitCast(previous, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) {
                signal(sig, SIG_IGN)
            }
        }

        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp) == 0 else {
            close(readEnd)
            close(writeEnd)
            return nil
        }
        chainedProcessGroup = pid
        close(readEnd)

        // The command may exit without draining stdin; that must not kill us.
        signal(SIGPIPE, SIG_IGN)
        let writer = FileHandle(fileDescriptor: writeEnd, closeOnDealloc: true)
        try? writer.write(contentsOf: input)
        try? writer.close()

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { break }
        }
        chainedProcessGroup = 0

        // Killed by a signal, or the shell couldn't find or run the command
        // (126 / 127, e.g. the user's script was deleted).
        let exited = (status & 0x7f) == 0
        let code = (status >> 8) & 0xff
        guard exited, code != 126, code != 127 else { return nil }
        return code
    }
}

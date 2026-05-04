# Claude macOS Monitor — Technical Plan v3.1

**Status:** Patched May 3, 2026 (supersedes v3)
**Previous versions:** v1 (WKWebView scraping), v2 (direct OAuth API), v3 (status line bridge), v3.1 (this — bug fixes + scope tightening for one-shot ship)
**Target:** macOS 14+ menu bar app showing Claude usage limits

---

## What Changed From v3

v3 was structurally sound but contained four implementation bugs and five unfinished decisions that would have caused a "deploys but doesn't work" moment. v3.1 fixes them and tightens scope so a single build cycle ships a working app.

**Bugs fixed:**
1. Status line script now writes atomically (`tmp + mv`) — v3's plain `>` redirect raced with the file watcher.
2. `FileWatcher` no longer double-closes the file descriptor (cancel handler owned cleanup, but `restart()` also closed it).
3. App entry point moved to `NSApplicationDelegateAdaptor` — v3 stored reference-type properties on the SwiftUI `App` struct, which has no guaranteed lifetime.
4. `AlertManager` now clears fired thresholds when the window's `resets_at` changes (not when percent drops below 70%) and persists state to `UserDefaults` so app restarts don't re-fire alerts.

**Scope tightened:**
5. Gate 0 (verify Claude Code's actual JSON schema) moved to a 30-minute pre-build step. Without this verified, do not start.
6. Code signing decision made: **ad-hoc signed, installed to `/Applications`, non-sandboxed**. No App Store, no Developer ID needed for v1.
7. Storage moved off `/tmp/` to `~/Library/Application Support/ClaudeMonitor/usage.json` — survives reboots, user-private, no entitlements needed.
8. Switched to `MenuBarExtra` (macOS 13+ declarative API) — eliminates ~60 lines of `NSStatusItem`/`NSPopover` boilerplate.
9. Preferences UI **descoped to v1.1**. v1 ships with hardcoded thresholds (70/85/95), launch-at-login toggle in the popover, and Quit. No settings sheet.
10. Status line installer (`install.sh`) included — uses `jq` to merge with existing `~/.claude/settings.json` rather than overwriting.

---

## Data We Display

Two metrics, sourced from Claude Code's status line JSON:

| Metric | JSON path | Type |
|---|---|---|
| 5-hour session usage % | `rate_limits.five_hour.used_percentage` | Float 0-100 |
| 5-hour reset time | `rate_limits.five_hour.resets_at` | Unix epoch seconds |
| 7-day weekly usage % | `rate_limits.seven_day.used_percentage` | Float 0-100 |
| 7-day reset time | `rate_limits.seven_day.resets_at` | Unix epoch seconds |

**Note:** These fields are only present for Claude.ai subscribers (Pro/Max) after the first API response in a Claude Code session. Each window may be independently absent.

---

## Gate 0 — Verify Before Building (30 min, do this first)

Before writing a line of Swift, prove the data exists in the shape the plan assumes. If this fails, the project is blocked regardless of how good the rest of the plan is.

```bash
# 1. Install a one-line debug status line
mkdir -p ~/.claude
cat > ~/.claude/debug-statusline.sh <<'EOF'
#!/bin/bash
cat > /tmp/claude-statusline-debug.json
echo "debug captured"
EOF
chmod +x ~/.claude/debug-statusline.sh

# 2. Wire it into Claude Code settings (back up first)
cp ~/.claude/settings.json ~/.claude/settings.json.bak 2>/dev/null || true
# Manually add or merge:
# {
#   "statusLine": { "type": "command", "command": "~/.claude/debug-statusline.sh" }
# }

# 3. Open Claude Code, send any message to a Pro/Max account
# 4. Inspect:
cat /tmp/claude-statusline-debug.json | jq .
```

**Pass criteria:** the JSON contains `.rate_limits.five_hour.used_percentage` (number) and `.rate_limits.five_hour.resets_at` (number). Same for `.seven_day`.

**If field names differ**, update the script (line 71-92) and the Swift `CodingKeys` (line 437-451 of this doc) before continuing.

**If `rate_limits` is absent entirely**, the project is blocked. Confirm Claude Code version is recent and the account is Pro/Max (not API-key-only).

Restore your previous status line config when done.

---

## Architecture Overview

```
┌─────────────────┐       JSON stdin       ┌────────────────────┐
│                  │ ────────────────────>  │                    │
│   Claude Code    │                        │  Status Line Script│
│  (runs normally) │                        │  statusline.sh     │
│                  │                        │                    │
└─────────────────┘                        └────────┬───────────┘
                                                     │
                                              writes JSON file (atomic)
                                                     │
                                                     ▼
                          ~/Library/Application Support/ClaudeMonitor/usage.json
                                                     │
                                              FSEvents file watch
                                                     │
                                                     ▼
                                           ┌─────────────────────┐
                                           │  Menu Bar App        │
                                           │  (Swift/SwiftUI)     │
                                           │                      │
                                           │  - MenuBarExtra      │
                                           │  - UNNotifications   │
                                           │  - SMAppService      │
                                           └─────────────────────┘
```

### Component 1: Status Line Script

A shell script installed at `~/.claude/claude-monitor-statusline.sh`. Claude Code calls it after each assistant message, piping JSON session data to stdin. The script:

1. Captures stdin once (Claude Code only sends it once per call).
2. Extracts `rate_limits` and writes it to the shared file **atomically** (write to `.tmp`, then `mv`).
3. Prints a one-line status for Claude Code's own status bar.

```bash
#!/bin/bash
set -euo pipefail

# Resolve the data directory (XDG-style, in ~/Library on macOS)
DATA_DIR="${HOME}/Library/Application Support/ClaudeMonitor"
DATA_FILE="${DATA_DIR}/usage.json"
TMP_FILE="${DATA_FILE}.tmp.$$"
mkdir -p "$DATA_DIR"

# Read stdin once
input=$(cat)

# Extract and write atomically. If jq fails, leave the previous file alone.
if echo "$input" | jq -e '.rate_limits' > /dev/null 2>&1; then
  echo "$input" | jq '{
    five_hour: .rate_limits.five_hour,
    seven_day: .rate_limits.seven_day,
    model: .model.display_name,
    updated_at: now
  }' > "$TMP_FILE" 2>/dev/null && mv -f "$TMP_FILE" "$DATA_FILE"
fi
rm -f "$TMP_FILE" 2>/dev/null || true

# Print status line for Claude Code display
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)

LIMITS=""
[ -n "$FIVE_H" ] && LIMITS="5h: $(printf '%.0f' "$FIVE_H")%"
[ -n "$WEEK" ] && LIMITS="${LIMITS:+$LIMITS | }7d: $(printf '%.0f' "$WEEK")%"

[ -n "$LIMITS" ] && echo "$LIMITS" || echo "..."
```

**Why atomic:** The Swift `FileWatcher` fires on file modification. A non-atomic `>` redirect truncates the file before writing, so the watcher can read an empty/partial file. The `tmp + mv` pattern makes the swap atomic at the filesystem level — readers either see the old file or the new file, never a half-written one. The watcher handles the resulting `.rename` event by re-opening.

### Status Line Installer (`install.sh`)

Ships in the app bundle. Handles three cases: no existing config, existing config without `statusLine`, existing config with a `statusLine` already set.

```bash
#!/bin/bash
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
SCRIPT_SRC="$(dirname "$0")/claude-monitor-statusline.sh"
SCRIPT_DEST="${CLAUDE_DIR}/claude-monitor-statusline.sh"

mkdir -p "$CLAUDE_DIR"
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"

# If no settings file, create minimal one
if [ ! -f "$SETTINGS" ]; then
  cat > "$SETTINGS" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "${SCRIPT_DEST}"
  }
}
EOF
  echo "Installed status line (new settings.json)."
  exit 0
fi

# If settings exists, check for existing statusLine
EXISTING=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)

if [ -z "$EXISTING" ]; then
  # No statusLine configured — merge ours in
  TMP=$(mktemp)
  jq --arg cmd "$SCRIPT_DEST" \
     '. + {statusLine: {type: "command", command: $cmd}}' \
     "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  echo "Added status line to existing settings.json."
elif [ "$EXISTING" = "$SCRIPT_DEST" ]; then
  echo "Status line already installed. Nothing to do."
else
  cat <<MSG
WARNING: You already have a status line configured:
  $EXISTING

ClaudeMonitor's status line is at:
  $SCRIPT_DEST

To use both, edit your existing script to call ours and pass stdin through:
  # At the top of your existing script, before reading stdin:
  input=\$(cat)
  echo "\$input" | $SCRIPT_DEST > /dev/null
  # Then continue your existing logic with \$input

Or replace your existing config manually in $SETTINGS.
MSG
  exit 1
fi
```

### Component 2: Menu Bar App (Swift)

Five modules. Lifecycle owned by an `AppDelegate` (the SwiftUI `App` struct is unreliable for holding non-`@StateObject` reference types).

#### Module 1: UsageStore (ObservableObject)

```swift
import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published var fiveHourPercent: Double? = nil
    @Published var fiveHourResetsAt: Date? = nil
    @Published var sevenDayPercent: Double? = nil
    @Published var sevenDayResetsAt: Date? = nil
    @Published var modelName: String? = nil
    @Published var lastUpdated: Date? = nil
    @Published var isStale: Bool = true  // true when no update in 5+ minutes

    private var staleTimer: Timer?

    func update(from data: UsageFileData) {
        if let fh = data.fiveHour {
            fiveHourPercent = fh.usedPercentage
            fiveHourResetsAt = fh.resetsAt.map { Date(timeIntervalSince1970: $0) }
        }
        if let sd = data.sevenDay {
            sevenDayPercent = sd.usedPercentage
            sevenDayResetsAt = sd.resetsAt.map { Date(timeIntervalSince1970: $0) }
        }
        modelName = data.model
        lastUpdated = Date()
        isStale = false
        resetStaleTimer()
    }

    private func resetStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isStale = true }
        }
    }

    /// Compact text for the menu bar label.
    var menuBarText: String {
        guard let pct = fiveHourPercent else { return "⚪ --" }
        let icon = pct >= 85 ? "🔴" : pct >= 60 ? "🟡" : "🟢"
        return "\(icon) \(Int(pct))%"
    }
}
```

#### Module 2: FileWatcher

Watches the data file using `DispatchSource`. **Critical fix from v3:** the file descriptor is closed in exactly one place — the cancel handler. `restart()` no longer double-closes.

```swift
import Foundation

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
        readFile()  // initial read if file already exists

        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
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
        source?.cancel()    // triggers setCancelHandler → close(fd)
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
```

#### Module 3: MenuBar Scene (replaces v3's StatusBarController)

Uses `MenuBarExtra` (macOS 13+). Eliminates the `NSStatusItem`/`NSPopover`/`NSHostingController` triad from v3.

```swift
import SwiftUI

@main
struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(store: appDelegate.store)
        } label: {
            // The label re-renders when @Published values on store change
            // because we observe via the popover's @ObservedObject. For the
            // label itself, we read a published property through a small
            // wrapper view so MenuBarExtra updates automatically.
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        Text(store.menuBarText)
    }
}
```

#### Module 4: AlertManager (rewritten)

Two correctness fixes from v3:
- Tracks each window's `resets_at`. When that timestamp changes, the fired-threshold set for that window is cleared (not when percent drops below 70%).
- Persists fired-threshold state to `UserDefaults` keyed by `(metric, resets_at)`, so app restarts don't re-fire.

```swift
import Foundation
import UserNotifications

@MainActor
final class AlertManager {
    private let thresholds: [Int] = [70, 85, 95]
    private let defaults = UserDefaults.standard

    /// Per-metric: last seen resets_at and the set of fired thresholds for that window.
    private struct WindowState: Codable {
        var resetsAt: Double
        var firedThresholds: Set<Int>
    }

    private func key(for metric: String) -> String { "alertState.\(metric)" }

    private func load(_ metric: String) -> WindowState? {
        guard let data = defaults.data(forKey: key(for: metric)) else { return nil }
        return try? JSONDecoder().decode(WindowState.self, from: data)
    }

    private func save(_ state: WindowState, for metric: String) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key(for: metric))
        }
    }

    func checkAndAlert(metric: String, percent: Double, resetsAt: Date?) {
        guard let resetsAt = resetsAt else { return }  // need a window key
        let resetsAtEpoch = resetsAt.timeIntervalSince1970

        var state = load(metric) ?? WindowState(resetsAt: resetsAtEpoch, firedThresholds: [])

        // New window detected — clear fired set.
        if state.resetsAt != resetsAtEpoch {
            state = WindowState(resetsAt: resetsAtEpoch, firedThresholds: [])
        }

        for threshold in thresholds {
            if Int(percent) >= threshold && !state.firedThresholds.contains(threshold) {
                state.firedThresholds.insert(threshold)
                sendNotification(
                    title: "Claude Usage Alert",
                    body: "\(metric) at \(Int(percent))%. \(resetString(resetsAt))"
                )
            }
        }

        save(state, for: metric)
    }

    private func resetString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "Resets \(f.localizedString(for: date, relativeTo: Date()))"
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Call once, the first time the popover opens — not at app launch.
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
}
```

#### Module 5: LoginItemController (replaces v3's PreferencesStore)

v3 conflated preferences with login items. Since v1 has no other preferences, this collapses to a single small controller. Note: requires the app to be ad-hoc signed and located in `/Applications` for `SMAppService` to behave correctly.

```swift
import Foundation
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Login item update failed: \(error.localizedDescription)")
        }
        refresh()
    }
}
```

---

## AppDelegate (lifecycle owner)

```swift
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = UsageStore()
    let alertManager = AlertManager()
    let loginItem = LoginItemController()
    private var fileWatcher: FileWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = Self.dataFilePath()

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

    static func dataFilePath() -> String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ClaudeMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.json").path
    }
}
```

---

## Data Models

```swift
struct UsageFileData: Codable {
    let fiveHour: RateLimitWindow?
    let sevenDay: RateLimitWindow?
    let model: String?
    let updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case model
        case updatedAt = "updated_at"
    }
}

struct RateLimitWindow: Codable {
    let usedPercentage: Double?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}
```

---

## SwiftUI Popover View

Drops the explicit `.frame(width:)` so `MenuBarExtra(.window)` sizes the popover from intrinsic content. Adds a Launch-at-Login toggle and a Quit button.

```swift
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @EnvironmentObject var loginItem: LoginItemController
    @State private var requestedPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude Usage").font(.headline)
                Spacer()
                if store.isStale {
                    Text("Stale").font(.caption).foregroundColor(.secondary)
                }
                if let model = store.modelName {
                    Text(model).font(.caption).foregroundColor(.secondary)
                }
            }

            Divider()

            UsageRow(label: "Current Session (5hr)",
                     percent: store.fiveHourPercent,
                     resetsAt: store.fiveHourResetsAt)
            UsageRow(label: "Weekly (7 day)",
                     percent: store.sevenDayPercent,
                     resetsAt: store.sevenDayResetsAt)

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .font(.caption)

            if let updated = store.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text("Waiting for Claude Code data…")
                    .font(.caption2).foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 280)
        .onAppear {
            if !requestedPermission {
                requestedPermission = true
                // Defer permission prompt to first popover open, not app launch.
                NotificationCenter.default.post(name: .requestNotificationPermission, object: nil)
            }
            loginItem.refresh()
        }
    }
}

extension Notification.Name {
    static let requestNotificationPermission = Notification.Name("requestNotificationPermission")
}

struct UsageRow: View {
    let label: String
    let percent: Double?
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(percent.map { "\(Int($0))%" } ?? "--")
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundColor(percentColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3).fill(percentColor)
                        .frame(width: geo.size.width * CGFloat((percent ?? 0) / 100.0))
                }
            }
            .frame(height: 6)

            if let reset = resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var percentColor: Color {
        guard let p = percent else { return .gray }
        if p >= 85 { return .red }
        if p >= 60 { return .orange }
        return .green
    }
}
```

The `AppDelegate` should observe the `requestNotificationPermission` notification and forward it to `alertManager.requestPermissionIfNeeded()`. (Or the popover can take an `EnvironmentObject` binding to `AlertManager` directly — equivalent.)

---

## App Entry Point

`Info.plist` requirement: `LSUIElement = YES` (Application is agent) so the app runs as a menu-bar-only process with no Dock icon. The `MenuBarExtra` scene replaces what v3 wired through `NSStatusItem`.

The full entry point (shown above in Module 3) is:

```swift
@main
struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(store: appDelegate.store)
                .environmentObject(appDelegate.loginItem)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}
```

---

## Code Signing & Distribution Decision

**v1 ships as: ad-hoc signed (`codesign --sign - --deep`), distributed as a `.zip` containing `ClaudeMonitor.app` + `install.sh`. User drags the app to `/Applications` and runs `install.sh`.**

Rationale:
- Personal-use / small-distribution scope. No App Store, no Developer ID requirement, no notarization fee.
- `SMAppService.mainApp.register()` works with ad-hoc signing if the app lives in `/Applications`.
- `UNUserNotificationCenter` works for ad-hoc signed apps in `/Applications` (would silently fail if run from `~/Downloads` or DerivedData).
- Non-sandboxed → can read the data file in `~/Library/Application Support/ClaudeMonitor/` regardless of which process wrote it.

**If later distributing more broadly:** apply Developer ID + notarization. No code changes required, only build pipeline changes.

---

## Implementation Plan

### Phase 0: Gate 0 (30 min — before writing any Swift)

Run the verification in the Gate 0 section above. Confirm `rate_limits.five_hour.used_percentage` and `.seven_day.used_percentage` exist with the expected types. If absent, stop and reassess.

### Phase 1: Status Line Script + File Watcher (Day 1)

1. Write `claude-monitor-statusline.sh` (atomic write version above)
2. Write `install.sh` (with merge logic above)
3. Manual test: install via `install.sh`, send Claude Code a message, confirm `~/Library/Application Support/ClaudeMonitor/usage.json` is written and contains expected fields
4. Create Xcode project (macOS App, SwiftUI lifecycle, deployment target macOS 14.0)
5. Set `LSUIElement = YES` in `Info.plist`
6. Implement `UsageFileData`, `RateLimitWindow`, `UsageStore`, `FileWatcher`, `AppDelegate`
7. Verify file watch triggers on script output (log to console for now)

### Phase 2: Menu Bar UI + Notifications (Day 2)

1. Implement `MenuBarExtra` scene + `MenuBarLabel`
2. Build `UsagePopoverView` + `UsageRow`
3. Implement `AlertManager` with persisted state
4. Wire `AppDelegate` to forward popover-open notification → `alertManager.requestPermissionIfNeeded()`
5. Test: simulate threshold crossings by editing the data file by hand (`echo '{"five_hour":{"used_percentage":71,"resets_at":...}}' > ...`)
6. Test: confirm fired alerts persist across app restart (don't re-fire) and clear when `resets_at` advances

### Phase 3: Login Item + Packaging (Day 3)

1. Implement `LoginItemController`, wire to popover toggle
2. Ad-hoc sign: `codesign --sign - --deep --force ClaudeMonitor.app`
3. Manual install test: copy app to `/Applications`, run `install.sh`, toggle Launch at Login on/off, restart Mac, confirm app starts
4. Package: `.zip` with app + `install.sh` + brief README
5. Smoke test on a clean macOS 14 user account

---

## Risks and Mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | `rate_limits` field absent from status line JSON | Blocker | **Gate 0 (Phase 0)** verifies before any Swift is written. |
| 2 | Claude Code not running = no data updates | Medium | Show "Stale" indicator after 5 min. Menu bar shows "⚪ --" when no data. App still launches and waits. |
| 3 | User has existing status line script | Low | `install.sh` detects and refuses to overwrite, prints chaining instructions. |
| 4 | Data file gets deleted (e.g., user clears Application Support) | Low | `FileWatcher.restart()` polls every 0.5s until file reappears. Script recreates on next Claude Code message. |
| 5 | Multiple Claude Code sessions write to same file | Low | Last-write-wins is acceptable for v1. Atomic mv prevents partial reads even with concurrent writers. |
| 6 | Anthropic changes status line JSON schema | Low | All fields are optional in the decoder. Missing data → "--" display. |
| 7 | App not in `/Applications` → SMAppService + notifications break | Medium | `install.sh` README instructs Applications-folder install. App could detect `Bundle.main.bundlePath` and warn if not in `/Applications`. |
| 8 | macOS 14+ requirement excludes older users | Low | `MenuBarExtra` requires macOS 13+, `SMAppService` requires 13+. Setting target to 14 simplifies testing. |

---

## Acceptance Criteria

0. Gate 0 verified: `rate_limits.five_hour.used_percentage` confirmed in real Claude Code stdin.
1. `install.sh` installs status line script and either creates or merges `~/.claude/settings.json` correctly. Refuses (with instructions) when an unrelated `statusLine` already exists.
2. Status line script writes `~/Library/Application Support/ClaudeMonitor/usage.json` atomically on each Claude Code message.
3. Menu bar icon shows color-coded 5-hour usage percentage (green <60, yellow 60–84, red ≥85).
4. Clicking icon opens `MenuBarExtra` window with 5-hour and 7-day usage bars and reset timers.
5. macOS notifications fire at 70%, 85%, and 95% thresholds — once per window. Do not re-fire on app restart within the same window. Re-fire after the window's `resets_at` advances.
6. App shows "Stale" state when no update received in 5+ minutes.
7. App handles missing file, partial data, and null fields without crashing.
8. App launches at login when toggled (when installed in `/Applications`, ad-hoc signed).
9. Quitting the app cleans up the file watcher (no leaked file descriptors).

---

## What v3.1 Removed / Deferred From v3

**Removed (replaced by simpler equivalents):**
- `StatusBarController` (NSStatusItem/NSPopover boilerplate) → `MenuBarExtra`
- `PreferencesStore` (full preferences abstraction) → `LoginItemController` (just login items)

**Deferred to v1.1:**
- User-configurable alert thresholds (hardcoded 70/85/95 in v1)
- Menu bar display option (5h vs 7d vs both — v1 always shows 5h)
- Settings sheet/window
- Per-session-aware filenames (last-write-wins for now)

**Bug fixes (no behavior change visible to user, but project would not have shipped without them):**
- Atomic file write in status line script
- Single-owner FD cleanup in `FileWatcher`
- `AppDelegate`-owned lifecycle for `FileWatcher` and `AlertManager`
- Window-aware (not percent-aware) reset of fired alerts in `AlertManager`
- Persisted fired-alerts state across app restarts

Component count: 9 (v2) → 5 (v3) → 5 (v3.1, but smaller per-module).
Estimated Swift LOC: ~1200 (v2) → ~400 (v3) → ~450 (v3.1; net +50 from atomicity, persistence, AppDelegate).
External dependencies: 0.

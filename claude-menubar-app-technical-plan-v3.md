# Claude macOS Monitor — Technical Plan v3

**Status:** Updated May 3, 2026
**Previous versions:** v1 (WKWebView scraping), v2 (direct OAuth API), v3 (status line bridge)
**Target:** macOS 14+ menu bar app showing Claude usage limits

---

## What Changed From v2

The v2 plan called for extracting OAuth tokens from macOS Keychain and polling `GET /api/oauth/usage` directly. Three developments killed that approach:

1. **Anthropic OAuth policy (Feb 2026):** Using OAuth tokens from Claude Pro/Max in third-party apps violates Consumer Terms of Service. Enforced technically and by policy.
2. **Aggressive rate limiting:** The `/api/oauth/usage` endpoint returns persistent 429s even at conservative intervals. GitHub issues closed as "not planned."
3. **Claude Code status line:** Claude Code now exposes `rate_limits.five_hour` and `rate_limits.seven_day` data to user-configurable status line scripts via JSON on stdin. This is the same data we need, already authenticated and rate-limit-managed internally.

**v3 architecture:** Two components. A Claude Code status line script writes usage data to a shared file. The Swift menu bar app watches that file and displays the data. Zero direct API calls. Fully TOS-compliant.

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

## Architecture Overview

```
┌─────────────────┐       JSON stdin       ┌────────────────────┐
│                  │ ────────────────────>  │                    │
│   Claude Code    │                        │  Status Line Script│
│  (runs normally) │                        │  statusline.sh     │
│                  │                        │                    │
└─────────────────┘                        └────────┬───────────┘
                                                     │
                                              writes JSON file
                                                     │
                                                     ▼
                                           /tmp/claude-usage.json
                                                     │
                                              FSEvents file watch
                                                     │
                                                     ▼
                                           ┌─────────────────────┐
                                           │  Menu Bar App        │
                                           │  (Swift/SwiftUI)     │
                                           │                      │
                                           │  - NSStatusItem icon │
                                           │  - SwiftUI popover   │
                                           │  - UNNotifications   │
                                           └─────────────────────┘
```

### Component 1: Status Line Script

A shell script installed at `~/.claude/claude-monitor-statusline.sh`. Claude Code calls it after each assistant message, piping JSON session data to stdin. The script does two things:

1. Extracts `rate_limits` from the JSON and writes it to `/tmp/claude-usage.json` with a timestamp.
2. Optionally prints a one-line status for Claude Code's own status bar (so the user doesn't lose their existing status line functionality).

```bash
#!/bin/bash
input=$(cat)

# Write usage data to shared file for the menu bar app
echo "$input" | jq '{
  five_hour: .rate_limits.five_hour,
  seven_day: .rate_limits.seven_day,
  model: .model.display_name,
  updated_at: now
}' > /tmp/claude-usage.json 2>/dev/null

# Print status line for Claude Code display (optional)
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

LIMITS=""
[ -n "$FIVE_H" ] && LIMITS="5h: $(printf '%.0f' "$FIVE_H")%"
[ -n "$WEEK" ] && LIMITS="${LIMITS:+$LIMITS | }7d: $(printf '%.0f' "$WEEK")%"

[ -n "$LIMITS" ] && echo "$LIMITS" || echo "..."
```

**Installation:** Add to `~/.claude/settings.json`:
```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/claude-monitor-statusline.sh"
  }
}
```

**Important:** If the user already has a status line configured, the script needs to be merged with their existing setup rather than replacing it. The installer should detect and handle this.

### Component 2: Menu Bar App (Swift)

A lightweight native macOS app with 5 modules:

#### Module 1: UsageStore (ObservableObject)

Central data model. Holds current usage state, publishes changes to SwiftUI views.

```swift
import Foundation
import Combine

@MainActor
class UsageStore: ObservableObject {
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
            if let resetEpoch = fh.resetsAt {
                fiveHourResetsAt = Date(timeIntervalSince1970: resetEpoch)
            }
        }
        if let sd = data.sevenDay {
            sevenDayPercent = sd.usedPercentage
            if let resetEpoch = sd.resetsAt {
                sevenDayResetsAt = Date(timeIntervalSince1970: resetEpoch)
            }
        }
        modelName = data.model
        lastUpdated = Date()
        isStale = false
        resetStaleTimer()
    }

    private func resetStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isStale = true
            }
        }
    }
}
```

#### Module 2: FileWatcher

Watches `/tmp/claude-usage.json` using DispatchSource (FSEvents). Parses the file and pushes updates to UsageStore.

```swift
import Foundation

class FileWatcher {
    private let filePath: String
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let onChange: (UsageFileData) -> Void

    init(path: String = "/tmp/claude-usage.json", onChange: @escaping (UsageFileData) -> Void) {
        self.filePath = path
        self.onChange = onChange
    }

    func start() {
        // Initial read if file exists
        readFile()

        fileDescriptor = open(filePath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            // File doesn't exist yet, poll until it does
            pollForFile()
            return
        }
        watchFile()
    }

    private func watchFile() {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was replaced (atomic write pattern), re-watch
                self?.restart()
            } else {
                self?.readFile()
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
        }

        self.source = source
        source.resume()
    }

    private func readFile() {
        guard let data = FileManager.default.contents(atPath: filePath),
              let parsed = try? JSONDecoder().decode(UsageFileData.self, from: data) else {
            return
        }
        onChange(parsed)
    }

    private func restart() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 { close(fileDescriptor) }
        fileDescriptor = -1

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start()
        }
    }

    private func pollForFile() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: self.filePath) {
                self.start()
            } else {
                self.pollForFile()
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
```

#### Module 3: StatusBarController

Manages the NSStatusItem (menu bar icon). Shows a compact usage indicator. Click opens the SwiftUI popover.

```swift
import AppKit
import SwiftUI

class StatusBarController {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let store: UsageStore

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(store: store)
        )

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            updateButtonTitle(nil)
        }
    }

    func updateButtonTitle(_ percent: Double?) {
        guard let button = statusItem.button else { return }
        if let pct = percent {
            let icon = pct >= 80 ? "🔴" : pct >= 60 ? "🟡" : "🟢"
            button.title = "\(icon) \(Int(pct))%"
        } else {
            button.title = "⚪ --"
        }
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

#### Module 4: AlertManager

Sends macOS notifications when usage crosses configurable thresholds (e.g., 70%, 85%, 95%).

```swift
import UserNotifications

class AlertManager {
    private var firedAlerts: Set<String> = []
    private let thresholds: [Double] = [70, 85, 95]

    func checkAndAlert(metric: String, percent: Double, resetsAt: Date?) {
        for threshold in thresholds {
            let key = "\(metric)-\(Int(threshold))"
            if percent >= threshold && !firedAlerts.contains(key) {
                firedAlerts.insert(key)
                sendNotification(
                    title: "Claude Usage Alert",
                    body: "\(metric) at \(Int(percent))%\(resetString(resetsAt))"
                )
            }
        }

        // Clear alerts when usage drops (after reset)
        if percent < thresholds.first ?? 70 {
            firedAlerts = firedAlerts.filter { !$0.hasPrefix(metric) }
        }
    }

    private func resetString(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return ". Resets \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
```

#### Module 5: PreferencesStore

Persists user settings (thresholds, launch at login, which metric to show in menu bar).

```swift
import Foundation

import ServiceManagement

class PreferencesStore: ObservableObject {
    @Published var alertThresholds: [Double] {
        didSet { UserDefaults.standard.set(alertThresholds, forKey: "alertThresholds") }
    }
    @Published var showInMenuBar: MenuBarDisplay {
        didSet { UserDefaults.standard.set(showInMenuBar.rawValue, forKey: "showInMenuBar") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }

    enum MenuBarDisplay: String, CaseIterable {
        case fiveHour = "5-Hour Session"
        case sevenDay = "7-Day Weekly"
        case both = "Both"
    }

    init() {
        self.alertThresholds = UserDefaults.standard.array(forKey: "alertThresholds") as? [Double] ?? [70, 85, 95]
        self.showInMenuBar = MenuBarDisplay(rawValue: UserDefaults.standard.string(forKey: "showInMenuBar") ?? "") ?? .fiveHour
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
    }

    /// Uses SMAppService (macOS 13+) to register/unregister as a login item.
    /// This is the modern replacement for SMLoginItemSetEnabled and does not
    /// require a helper bundle. The app appears in System Settings > General >
    /// Login Items automatically.
    private func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("Login item update failed: \(error.localizedDescription)")
        }
    }

    /// Check actual system state on launch (user may have toggled it in
    /// System Settings directly, which doesn't call our didSet).
    func syncLoginItemState() {
        let status = SMAppService.mainApp.status
        let systemEnabled = (status == .enabled)
        if launchAtLogin != systemEnabled {
            launchAtLogin = systemEnabled
        }
    }
}
```

---

## Data Models

```swift
// What the status line script writes to /tmp/claude-usage.json
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

```swift
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if store.isStale {
                    Text("Stale")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let model = store.modelName {
                    Text(model)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // 5-hour session
            UsageRow(
                label: "Current Session (5hr)",
                percent: store.fiveHourPercent,
                resetsAt: store.fiveHourResetsAt
            )

            // 7-day weekly
            UsageRow(
                label: "Weekly (7 day)",
                percent: store.sevenDayPercent,
                resetsAt: store.sevenDayResetsAt
            )

            Divider()

            // Last updated
            if let updated = store.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("Waiting for Claude Code data...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Quit button
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 280)
    }
}

struct UsageRow: View {
    let label: String
    let percent: Double?
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(percent.map { "\(Int($0))%" } ?? "--")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(percentColor)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(percentColor)
                        .frame(width: geo.size.width * CGFloat((percent ?? 0) / 100.0))
                }
            }
            .frame(height: 6)

            // Reset timer
            if let reset = resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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

---

## App Entry Point

**Info.plist requirement:** Set `LSUIElement = YES` (Application is agent) so the app runs as a menu-bar-only process with no Dock icon and no main window.

```swift
import SwiftUI

@main
struct ClaudeMonitorApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var preferences = PreferencesStore()
    private let alertManager = AlertManager()
    private var fileWatcher: FileWatcher?
    private var statusBarController: StatusBarController?

    init() {
        let store = UsageStore()
        let preferences = PreferencesStore()
        let alertManager = AlertManager()
        alertManager.requestPermission()

        // Sync login item state with what System Settings actually shows
        preferences.syncLoginItemState()

        let controller = StatusBarController(store: store)

        let watcher = FileWatcher { data in
            Task { @MainActor in
                store.update(from: data)
                controller.updateButtonTitle(store.fiveHourPercent)

                if let pct = store.fiveHourPercent {
                    alertManager.checkAndAlert(
                        metric: "5-hour session",
                        percent: pct,
                        resetsAt: store.fiveHourResetsAt
                    )
                }
                if let pct = store.sevenDayPercent {
                    alertManager.checkAndAlert(
                        metric: "7-day weekly",
                        percent: pct,
                        resetsAt: store.sevenDayResetsAt
                    )
                }
            }
        }
        watcher.start()

        self._store = StateObject(wrappedValue: store)
        self._preferences = StateObject(wrappedValue: preferences)
        self.fileWatcher = watcher
        self.statusBarController = controller
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
```

---

## Implementation Plan

### Phase 1: Status Line Script + File Watcher (Day 1)

**Gate 0 validation (first hour):**
- Install the status line script in Claude Code
- Verify `rate_limits` data appears in the JSON stdin (start a Claude Code session, send a message, check the output)
- Confirm `/tmp/claude-usage.json` gets written

If Gate 0 fails (rate_limits not in stdin), the project is blocked until Anthropic adds the field. Check the Claude Code version and docs.

**Tasks:**
1. Write and install `claude-monitor-statusline.sh`
2. Create Xcode project (macOS App, SwiftUI lifecycle)
3. Implement `UsageFileData` model
4. Implement `FileWatcher` with DispatchSource
5. Implement `UsageStore`
6. Verify file watch triggers on script output

### Phase 2: Menu Bar UI + Notifications (Day 2)

1. Implement `StatusBarController` with NSStatusItem
2. Build `UsagePopoverView` in SwiftUI
3. Implement `AlertManager` with UNUserNotification
4. Wire up threshold alerts (70%, 85%, 95%)
5. Add "stale data" indicator (no update in 5+ minutes)
6. Test notification flow

### Phase 3: Polish + Preferences (Day 3)

1. Implement `PreferencesStore`
2. Add preferences UI (thresholds, menu bar display option, launch at login)
3. Handle edge cases: Claude Code not running, file missing, partial data
4. Add installer script that sets up the status line config
5. App icon and menu bar icon design
6. Build for distribution (sign, notarize if needed)

---

## Risks and Mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | `rate_limits` field absent from status line JSON | Blocker | Gate 0 day-one check. Field is documented in official Claude Code docs as of May 2026. Only appears after first API response in session. |
| 2 | Claude Code not running = no data updates | Medium | Show "stale" indicator with last-known values. Menu bar shows "-- " when no data. App still launches and waits. |
| 3 | User has existing status line script | Low | Installer detects existing config and merges, or provides instructions for manual merge. |
| 4 | `/tmp/` file gets cleaned by OS | Low | FileWatcher polls for file existence if deleted. Script recreates on next Claude Code message. |
| 5 | Multiple Claude Code sessions write to same file | Low | Last-write-wins is acceptable. Could use session-aware filenames in a future version. |
| 6 | Anthropic changes status line JSON schema | Low | App handles missing/null fields gracefully. JSON decoding uses optional fields throughout. |
| 7 | App sandbox restrictions on /tmp/ access | Low | Non-sandboxed app (no App Store distribution planned). If sandboxed, use App Group container instead. |

---

## Acceptance Criteria

0. Status line script installs and writes `/tmp/claude-usage.json` on each Claude Code message
1. Menu bar icon shows color-coded usage percentage (green/yellow/red)
2. Clicking icon opens popover with 5-hour and 7-day usage bars
3. Countdown timers show time until each limit resets
4. macOS notifications fire at 70%, 85%, and 95% thresholds
5. App shows "stale" state when Claude Code hasn't sent data in 5+ minutes
6. App handles missing file, partial data, and null fields without crashing
7. App launches at login (configurable)
8. Alert thresholds are user-configurable

---

## What v3 Removed From v2

These components are no longer needed:

- **OAuthTokenManager** — no token extraction or refresh
- **UsageAPIClient** — no direct API calls
- **DOMFallbackFetcher / WKWebView** — no web scraping fallback
- **RefreshScheduler** — Claude Code handles polling internally
- **Three-layer token refresh strategy** — not our problem anymore
- **Clock skew handling** — reset times come as Unix epochs from the server
- **Keychain access validation** — we never touch the Keychain
- **anthropic-version header management** — no HTTP requests at all

Component count: 9 (v2) reduced to 5 (v3).
Lines of Swift (estimated): ~1200 (v2) reduced to ~400 (v3).
External dependencies: 0.

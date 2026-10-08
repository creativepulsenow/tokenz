# ClaudeMonitor

A native macOS menu bar app that shows your Claude usage limits at a glance.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

<p align="center">
  <img src="docs/screenshot.png" alt="ClaudeMonitor menu bar and popover" width="540">
</p>

A tiny indicator in the menu bar — green under 60%, orange between 60–85%,
red above 85% — tells you where you stand on Claude Code's 5-hour session
and 7-day weekly windows. Click for exact percentages, time until each
window resets, and a Launch-at-Login toggle. Get a notification at 70%,
85%, and 95% so you know before you hit the wall.

No daemons. No network. No account sign-in. ClaudeMonitor reads the
rate-limit data Claude Code already hands to its status line command,
writes it to a small local JSON file, and watches that file for changes.
That's it.

## Why this exists

If you've used Claude Code on Pro or Max, you know how this goes. You're deep in a coding session, the responses slow down or stop, and you discover you've burned the 5-hour window or your week. At that point the only options are wait it out or switch to API billing. Neither is what you want mid-task.

Anthropic shows usage in the web console, but you have to go look. There's no signal on your machine while you work. ClaudeMonitor is that signal. Percentage in the menu bar, notifications at 70 / 85 / 95%, popover with reset times.

## Highlights

- **Glanceable** — asterisk + percentage in the menu bar, plus a `· 1h 23m` countdown to the next 5-hour reset so you can read both numbers at a glance.
- **Threshold notifications** — one alert per threshold crossing per window. No storms on first install at 95%.
- **Honest about uncertainty** — past 90 seconds without a fresh update, the menu bar prefixes the last-known number with a tilde (`~94%`) to signal "approximate." The number stays up for as long as its 5-hour window lasts; once the window rolls over it shows `~0%`. The popover shows a warning banner the whole time.
- **Launch at Login** — one-click toggle, backed by `SMAppService`.
- **One-click setup** — a **Connect to Claude Code** button in the app does the wiring. No Terminal, no Homebrew, no `jq`. If you already have a custom status line, it keeps showing.
- **Tiny** — about 1,400 lines of Swift. Zero third-party dependencies.
- **Private** — everything stays on your machine; the app makes zero network calls. Inputs are sanitized at the boundary so a misbehaving cohabitant can't crash or spoof the UI.

## Requirements

- macOS 14.0 (Sonoma) or later
- [Claude Code](https://claude.com/claude-code) installed
- Claude.ai Pro or Max subscription (rate limit data only appears on these tiers)

## Install (prebuilt)

1. Download **`ClaudeMonitor-1.3.0.dmg`** from the [latest release](https://github.com/creativepulsenow/claude-usage-taskbar-macos/releases/latest).
2. Open the DMG and drag `ClaudeMonitor.app` onto the Applications shortcut.
   *(Connecting to Claude Code, "Launch at Login" and notifications all need the app to live in `/Applications`.)*
3. Launch `ClaudeMonitor.app` from `/Applications`. **First time only:** macOS will refuse to open it because the app is ad-hoc signed and not yet notarized. Open **System Settings → Privacy & Security**, scroll down to the message about ClaudeMonitor, and click **Open Anyway**. (On macOS 14 you can instead right-click the app → **Open**.) Every later launch is normal.
4. Click the menu bar item, then **Connect to Claude Code**.
   This adds a `statusLine` entry to `~/.claude/settings.json`. The app saves a backup of the file first, changes nothing else in it, refuses if the file isn't valid JSON, and writes through symlinks so dotfile managers keep working.
5. Quit and relaunch Claude Code, then send any message so it reports the first batch of usage data.

You should see an asterisk and a percentage in your menu bar.

The bundled `.app` is a universal binary (Apple Silicon + Intel).

**Already have a status line?** Connect keeps it. ClaudeMonitor runs first, then hands the same input to your command and shows its output, so your status line looks the same as before.

**Upgrading from 1.2 or earlier?** Your existing setup keeps working. The popover offers **Update Connection** to switch from the old `jq` script to the built-in one; afterward you can delete `~/.claude/claude-monitor-statusline.sh`.

**Prefer to edit the file yourself?** Add this to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "'/Applications/ClaudeMonitor.app/Contents/MacOS/ClaudeMonitor' --statusline"
}
```

## Build from source

```bash
brew install xcodegen
xcodegen generate
open ClaudeMonitor.xcodeproj
```

Build the `ClaudeMonitor` scheme, then drag the resulting `.app` to `/Applications`.

To produce the same DMG that ships in releases:

```bash
./Scripts/make-dmg.sh
# -> build/ClaudeMonitor-<version>.dmg
```

## How it works

```
Claude Code ──(stdin JSON)──▶ ClaudeMonitor --statusline ──▶ ~/Library/Application Support/ClaudeMonitor/usage.json
                                                                        │
                                                       (DispatchSource FSEvents)
                                                                        │
                                                                        ▼
                                                               ClaudeMonitor.app
                                                            (menu bar + notifications)
```

- Claude Code runs the app's binary in `--statusline` mode after each assistant message and pipes session JSON to it on stdin. In that mode the binary does its job in a few milliseconds and exits; it never opens a window.
- It keeps only `rate_limits` and the model name, and writes them atomically to a small owner-only JSON file in Application Support.
- The app watches that file with `DispatchSource.makeFileSystemObjectSource` and re-renders on every change. As a safety net it also checks the file's modification time every 10 seconds.
- Alerts fire once per threshold per window; state persists in `UserDefaults` so restarts don't re-fire.

**No network calls. No daemons. No polling of Anthropic.** The app makes zero API requests against Anthropic — it only reads what your local Claude tools have already pulled. ClaudeMonitor consumes **zero quota**.

### Update cadence

ClaudeMonitor isn't a poller — it's a passive observer. The cadence comes entirely from your local Claude tools running the status-line hook:

- **Active session (Claude Code or Cowork actively responding):** updates every assistant turn — typically every 5–30 seconds during back-and-forth, less often during long tool-heavy responses. File-write to UI latency is sub-second.
- **Local Claude tool open but idle:** no updates.
- **No local Claude tool running at all:** no updates. After 90 seconds the menu bar swaps to a tilde-prefixed approximation (`~94%`) and the popover banners it. It keeps showing that last-known number until the 5-hour window rolls over, then shows `~0%`: usage only moves when you use Claude, so the last reading stays right while you're idle.

Practical effect: the menu bar is always *"current as of your last assistant reply,"* which is what you usually want when you're working. The one thing a tilde number can miss is usage from claude.ai web, mobile or another machine; send any message in Claude Code or Cowork to pick that up.

#### Why the menu bar can show 1% less than the Anthropic web console

If you compare the pill to claude.ai's account page mid-conversation, the web will sometimes read 1% (occasionally 2%) higher. That's not a bug — it's the architectural floor of a passive observer:

```
turn N starts → model generates → turn N completes → status-line fires
                                                          ↓
                                             rate_limits as of end of turn N
                                                          ↓
                                                 file → watcher → UI
```

The status-line hook fires **after** an assistant message completes. The web console, on the other hand, reads the live account state, which has already been debited by whatever message is currently in flight. So while you're watching a long response generate, the console is *N+1* and the pill is still showing *N*. As soon as the response finishes, the script fires and the pill catches up within a second.

Closing that 1-turn gap would require actively polling `api.anthropic.com`, which means user-supplied API keys, network calls in the privacy posture, and rate-limit-checks that themselves eat into your rate limits. Not worth it for the gap it closes. **1 turn behind is the floor.** When the pill matches the previous turn's value, the system is healthy.

### What ClaudeMonitor sees

Rate limits live on your Anthropic account, but ClaudeMonitor only learns about them through local tools that fire the status-line hook. Coverage by surface:

| Surface | Updates the menu bar? |
|---|---|
| Claude Code (CLI / IDE) | ✅ every assistant turn |
| Claude desktop app + Cowork (local agents) | ✅ inherits the same `statusLine` config from `~/.claude/settings.json` |
| Claude.ai web chat | ❌ nothing local runs |
| Claude mobile / iPad app | ❌ nothing local runs |

The good news: rate limits are account-wide, so whatever you burn through web chat or mobile is *visible to ClaudeMonitor as soon as the next Claude Code or Cowork turn fires.* The hook reports the current account-wide percentages, so consumption from other surfaces catches up with at most one assistant-turn of delay. If you only ever use claude.ai web chat, ClaudeMonitor won't be useful — it has nothing to react to.

## Reliability & limits

ClaudeMonitor is best-effort. A few caveats before you rely on it:

- **It only sees what your local Claude Code (or Cowork) sees.** If you only use claude.ai web or mobile, the status-line hook never fires, so the app has nothing to show.
- **It's at least one assistant turn behind live account state.** Structural, not a bug — see [Update cadence](#update-cadence).
- **Notifications can be missed.** Thresholds (70 / 85 / 95%) only fire when the app is running and a status-line update arrives that crosses them. Cross 85% via web chat while ClaudeMonitor is closed and you'll skip that alert — only the next unfired threshold counts.
- **The 95% alert is late by design.** By the time it fires you're nearly out for the window. If you want earlier warning, watch for the 70% one.
- **The percentage gets fuzzier as it ages.** Past 90 seconds without fresh data, the menu bar adds a tilde — `~94%` instead of `94%` — to flag that the number is approximate. It stays on screen until the 5-hour window rolls over, then reads `~0%`. A tilde number doesn't include anything you used on claude.ai web, mobile or another machine since the last update. Run any prompt in Claude Code to get an exact reading.

Use it as background information. If hitting a window mid-task would cost you real money or break a deadline, you'll want your own habit running too.

## Security & sandboxing notes

- All inputs are sanitized at the boundary. The app refuses non-finite or
  out-of-range percentages, clamps reset timestamps to a ±1y window, and
  strips control / bidi-override characters from the model name. A buggy or
  hostile cohabiting process can't crash the app by writing junk to
  `usage.json`.
- Notifications fire at most one per threshold crossing per window. A first
  install at 95% gets one notification, not three.
- The app reads `usage.json` only if it is a small regular file, never a
  symlink or anything oversized. The file and its directory are owner-only.
- Connect changes one entry in `~/.claude/settings.json` and nothing else. It
  saves a timestamped backup next to the file first, re-parses its own edit
  and refuses to write if anything other than `statusLine` would differ,
  refuses to touch a file that isn't valid JSON, and writes through symlinks
  so dotfile managers (stow, chezmoi, yadm) keep working.
- The app never sees your Claude login. It has no access to tokens, the
  Keychain, or your conversations: only the percentages Claude Code passes
  to its status line.
- Release builds use the hardened runtime and carry no debug entitlements.
- The only program the app ever starts is your own previous status line
  command, and only if you had one when you connected.
- The app currently runs **without** the macOS sandbox, because it has to
  edit `~/.claude/settings.json` and share an Application Support path with
  the `--statusline` process that Claude Code launches.
- The app is ad-hoc signed and not yet notarized, so macOS can't verify who
  built it. Check the SHA-256 on the release page, or build from source.

## Uninstall

1. Click the menu bar item, then **Disconnect from Claude Code**. This removes the `statusLine` entry from `~/.claude/settings.json`, or puts your previous status line back if you had one.
2. Quit ClaudeMonitor.
3. Move `ClaudeMonitor.app` to the Trash.
4. Optional: `rm -rf ~/Library/Application\ Support/ClaudeMonitor`, and delete the `settings.json.claudemonitor-backup-*` files in `~/.claude`.

## Privacy

All data stays on your machine. The status line command reads what Claude Code already pipes to it,
writes it to a local file, and the menu bar app reads that local file. Nothing is sent anywhere.

## Disclaimer

This is an independent, community project. It is **not affiliated with,
endorsed by, or sponsored by Anthropic**. "Claude" and "Claude Code" are
trademarks of Anthropic, used here only to describe what the app integrates
with (nominative fair use).

The app reads only the rate-limit data that Claude Code already pipes to its
status line command. If Anthropic changes that data shape, the app will
gracefully show no data until updated.

**No warranty. Use at your own risk.** Provided "as is" — see [LICENSE](LICENSE) for the full text. It will miss limit crossings sometimes, and it can't stop you from being charged or rate-limited. If overage actually matters for your work, don't rely on this app alone to catch it.

## Background

Curious how this is built? The original technical plans walk through the
design rationale, the alternatives that were rejected (WKWebView scraping,
direct OAuth API), and the bug-by-bug evolution from v3 to the shipping v1:

- [docs/technical-plan-v3.md](docs/technical-plan-v3.md) — original plan
- [docs/technical-plan-v3.1.md](docs/technical-plan-v3.1.md) — patched plan that shipped

## License

MIT — see [LICENSE](LICENSE).

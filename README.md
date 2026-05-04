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

No daemons. No polling. No network. ClaudeMonitor reads the rate-limit
data Claude Code already pipes to its status-line script, writes it to a
small local JSON file, and watches that file for changes. That's it.

## Highlights

- **Glanceable** — colored dot + percentage in the menu bar, always visible.
- **Threshold notifications** — one alert per threshold crossing per window. No storms on first install at 95%.
- **Honest about uncertainty** — shows "Stale" if data hasn't updated in 5 minutes, and a clear "Pro/Max required" hint if rate-limit data isn't being reported for your plan.
- **Launch at Login** — one-click toggle, backed by `SMAppService`.
- **Tiny** — ~600 lines of Swift, ~120 lines of bash. Zero third-party dependencies.
- **Private** — everything stays on your machine; the app makes zero network calls. Inputs are sanitized at the boundary so a misbehaving cohabitant can't crash or spoof the UI.

## Requirements

- macOS 14.0 (Sonoma) or later
- [Claude Code](https://claude.com/claude-code) installed
- Claude.ai Pro or Max subscription (rate limit data only appears on these tiers)
- `jq` — install with `brew install jq`

## Install (prebuilt)

1. Download **`ClaudeMonitor-1.1.0.dmg`** from the [latest release](https://github.com/creativepulsenow/claude-usage-taskbar-macos/releases/latest).
2. Open the DMG and drag `ClaudeMonitor.app` onto the Applications shortcut.
   *(`SMAppService` for "Launch at Login" and notification permissions both require the app to live in `/Applications`.)*
3. Open Terminal in the mounted DMG window and run `./install.sh`.
   This wires up the Claude Code status-line bridge in `~/.claude/settings.json` (non-destructive merge — refuses if the file isn't valid JSON, follows symlinks for dotfile managers).
4. Quit and relaunch Claude Code.
5. Send any message in Claude Code so it pipes the first batch of usage data.
6. Launch `ClaudeMonitor.app` from `/Applications`. **First time only:** macOS will say "ClaudeMonitor cannot be opened because the developer cannot be verified." Right-click the app → **Open** → confirm. (The app is ad-hoc signed; not yet notarized — every subsequent launch is normal.)

You should see a colored circle and percentage in your menu bar.

The bundled `.app` is a universal binary (Apple Silicon + Intel).

## Build from source

```bash
brew install xcodegen jq
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
Claude Code ──(stdin JSON)──▶ status line script ──▶ ~/Library/Application Support/ClaudeMonitor/usage.json
                                                                        │
                                                       (DispatchSource FSEvents)
                                                                        │
                                                                        ▼
                                                               ClaudeMonitor.app
                                                            (menu bar + notifications)
```

- Claude Code calls the status line script after each assistant message and pipes session JSON to it on stdin.
- The script extracts `rate_limits` and writes it atomically to a small JSON file in Application Support.
- The app watches that file with `DispatchSource.makeFileSystemObjectSource` and re-renders on every change.
- Alerts fire once per threshold per window; state persists in `UserDefaults` so restarts don't re-fire.

**No network calls. No daemons. No polling.** The app makes zero API requests against Anthropic — it only reads what your local Claude tools have already pulled. ClaudeMonitor consumes **zero quota**.

### Update cadence

ClaudeMonitor isn't a poller — it's a passive observer. The cadence comes entirely from your local Claude tools running the status-line hook:

- **Active session (Claude Code or Cowork actively responding):** updates every assistant turn — typically every 5–30 seconds during back-and-forth, less often during long tool-heavy responses. File-write to UI latency is sub-second.
- **Local Claude tool open but idle:** no updates.
- **No local Claude tool running at all:** no updates. The popover keeps showing the last-known values, with a "Stale" pill appearing after 5 minutes.

Practical effect: the menu bar is always *"current as of your last assistant reply,"* which is what you usually want when you're working. If you've been away and just want to glance at the live number, you'll need to send any message in Claude Code or Cowork to refresh.

### What ClaudeMonitor sees

Rate limits live on your Anthropic account, but ClaudeMonitor only learns about them through local tools that fire the status-line hook. Coverage by surface:

| Surface | Updates the menu bar? |
|---|---|
| Claude Code (CLI / IDE) | ✅ every assistant turn |
| Claude desktop app + Cowork (local agents) | ✅ inherits the same `statusLine` config from `~/.claude/settings.json` |
| Claude.ai web chat | ❌ nothing local runs |
| Claude mobile / iPad app | ❌ nothing local runs |

The good news: rate limits are account-wide, so whatever you burn through web chat or mobile is *visible to ClaudeMonitor as soon as the next Claude Code or Cowork turn fires.* The hook reports the current account-wide percentages, so consumption from other surfaces catches up with at most one assistant-turn of delay. If you only ever use claude.ai web chat, ClaudeMonitor won't be useful — it has nothing to react to.

## Security & sandboxing notes

- All inputs are sanitized at the boundary. The app refuses non-finite or
  out-of-range percentages, clamps reset timestamps to a ±1y window, and
  strips control / bidi-override characters from the model name. A buggy or
  hostile cohabiting process can't crash the app by writing junk to
  `usage.json`.
- Notifications fire at most one per threshold crossing per window. A first
  install at 95% gets one notification, not three.
- The installer refuses to touch `~/.claude/settings.json` if the file isn't
  valid JSON, and follows symlinks to their target so dotfile managers
  (stow, chezmoi, yadm) keep working.
- The app currently runs **without** the macOS sandbox so the unsandboxed
  status line script and the app can share a single Application Support
  path. A future release may move data into a sandbox container; the
  external path will continue to work via a small shim.

## Uninstall

1. Quit ClaudeMonitor.
2. Move `ClaudeMonitor.app` to the Trash.
3. Edit `~/.claude/settings.json` and remove the `statusLine` entry (or restore a previous one).
4. Optional: `rm -rf ~/Library/Application\ Support/ClaudeMonitor`.

## Privacy

All data stays on your machine. The status line script reads what Claude Code already pipes to it,
writes it to a local file, and the menu bar app reads that local file. Nothing is sent anywhere.

## Disclaimer

This is an independent, community project. It is **not affiliated with,
endorsed by, or sponsored by Anthropic**. "Claude" and "Claude Code" are
trademarks of Anthropic, used here only to describe what the app integrates
with (nominative fair use).

The app reads only the rate-limit data that Claude Code already pipes to its
status line script. If Anthropic changes that data shape, the app will
gracefully show no data until updated.

## Background

Curious how this is built? The original technical plans walk through the
design rationale, the alternatives that were rejected (WKWebView scraping,
direct OAuth API), and the bug-by-bug evolution from v3 to the shipping v1:

- [docs/technical-plan-v3.md](docs/technical-plan-v3.md) — original plan
- [docs/technical-plan-v3.1.md](docs/technical-plan-v3.1.md) — patched plan that shipped

## License

MIT — see [LICENSE](LICENSE).

# ClaudeMonitor

A macOS menu bar app that displays your Claude usage limits.

Shows your current 5-hour session and 7-day weekly usage as a colored
indicator in the menu bar, with notifications when you cross 70%, 85%,
and 95% thresholds.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Requirements

- macOS 14.0 (Sonoma) or later
- [Claude Code](https://claude.com/claude-code) installed
- Claude.ai Pro or Max subscription (rate limit data only appears on these tiers)
- `jq` — install with `brew install jq`

## Install (prebuilt)

1. Download the latest `ClaudeMonitor-1.0.0.zip` from Releases and unzip.
2. Drag `ClaudeMonitor.app` to `/Applications`.
   *(SMAppService for "Launch at Login" and notification permissions both require the app to live in `/Applications`.)*
3. Run `./install.sh` from the unzipped folder. This installs the
   status line bridge into `~/.claude/settings.json` (merging non-destructively
   with an existing config).
4. Quit and relaunch Claude Code.
5. Send any message in Claude Code so it writes the first batch of usage data.
6. Launch `ClaudeMonitor.app`.

You should see a colored circle and percentage in your menu bar.

## Build from source

```bash
brew install xcodegen
xcodegen generate
open ClaudeMonitor.xcodeproj
```

Build the `ClaudeMonitor` scheme, then drag the resulting `.app` to `/Applications`.

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

No network calls. No daemons. No polling. The app only reacts to writes from Claude Code itself.

## Uninstall

1. Quit ClaudeMonitor.
2. Move `ClaudeMonitor.app` to the Trash.
3. Edit `~/.claude/settings.json` and remove the `statusLine` entry (or restore a previous one).
4. Optional: `rm -rf ~/Library/Application\ Support/ClaudeMonitor`.

## Privacy

All data stays on your machine. The status line script reads what Claude Code already pipes to it,
writes it to a local file, and the menu bar app reads that local file. Nothing is sent anywhere.

## License

See `LICENSE`.

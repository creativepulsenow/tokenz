# Tokenz

Usage limits for Claude Code in your menu bar. A native macOS app that shows where you stand at a glance.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

<p align="center">
  <img src="docs/screenshot.png" alt="Tokenz menu bar and popover" width="540">
</p>

A tiny indicator in the menu bar — green under 60%, orange between 60–85%,
red above 85% — tells you where you stand on Claude Code's 5-hour session
and 7-day weekly windows. Click for exact percentages, time until each
window resets, and a Launch-at-Login toggle. Get a notification at 70%,
85%, and 95% so you know before you hit the wall.

No daemons. No network. No account sign-in. Tokenz reads the
rate-limit data Claude Code already hands to its status line command,
writes it to a small local JSON file, and watches that file for changes.
That's it.

## Why this exists

If you've used Claude Code on Pro or Max, you know how this goes. You're deep in a coding session, the responses slow down or stop, and you discover you've burned the 5-hour window or your week. At that point the only options are wait it out or switch to API billing. Neither is what you want mid-task.

Anthropic shows usage in the web console, but you have to go look. There's no signal on your machine while you work. Tokenz is that signal. Percentage in the menu bar, notifications at 70 / 85 / 95%, popover with reset times.

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

1. Download **`Tokenz-1.4.1.dmg`** from the [latest release](https://github.com/creativepulsenow/tokenz/releases/latest).
2. Open the DMG and drag `Tokenz.app` onto the Applications shortcut.
   *(Connecting to Claude Code, "Launch at Login" and notifications all need the app to live in `/Applications`.)*
3. Launch `Tokenz.app` from `/Applications`. **First time only:** macOS will refuse to open it because the app is ad-hoc signed and not yet notarized. Open **System Settings → Privacy & Security**, scroll down to the message about Tokenz, and click **Open Anyway**. (On macOS 14 you can instead right-click the app → **Open**.) Every later launch is normal.
4. Click the menu bar item, then **Connect to Claude Code**.
   This adds a `statusLine` entry to `~/.claude/settings.json`. The app saves a backup of the file first, changes nothing else in it, refuses if the file isn't valid JSON, and writes through symlinks so dotfile managers keep working.
5. Send any message in Claude Code so it reports the first batch of usage data. (If nothing shows up, quit and relaunch Claude Code once.)

You should see an asterisk and a percentage in your menu bar.

The bundled `.app` is a universal binary (Apple Silicon + Intel).

**Already have a status line?** Connect keeps it. Tokenz runs first, then hands the same input to your command and shows its output, so your status line looks the same as before.

**Upgrading from ClaudeMonitor?** Tokenz is the same app under a new name (1.3 and earlier shipped as ClaudeMonitor). Install Tokenz, open it, and click **Update Connection**. Then delete `ClaudeMonitor.app`, and optionally `~/Library/Application Support/ClaudeMonitor` and `~/.claude/claude-monitor-statusline.sh`. Launch at Login and notifications need to be turned on again.

**Prefer to edit the file yourself?** Add this to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "'/Applications/Tokenz.app/Contents/MacOS/Tokenz' --statusline"
}
```

## Build from source

```bash
brew install xcodegen
xcodegen generate
open Tokenz.xcodeproj
```

Build the `Tokenz` scheme, then drag the resulting `.app` to `/Applications`.

To produce the same DMG that ships in releases:

```bash
./Scripts/make-dmg.sh
# -> build/Tokenz-<version>.dmg
```

## How it works

```
Claude Code ──(stdin JSON)──▶ Tokenz --statusline ──▶ ~/Library/Application Support/Tokenz/usage.json
                                                                        │
                                                       (DispatchSource FSEvents)
                                                                        │
                                                                        ▼
                                                               Tokenz.app
                                                            (menu bar + notifications)
```

- Claude Code runs the app's binary in `--statusline` mode after each assistant message and pipes session JSON to it on stdin. In that mode the binary does its job in a few milliseconds and exits; it never opens a window.
- It keeps only `rate_limits` and the model name, and writes them atomically to a small owner-only JSON file in Application Support.
- With several Claude Code sessions open, each one re-runs the status line now and then with the numbers from its own last reply. Tokenz only accepts a reading from a session that has had a new reply since its last run, so an idle session can't overwrite the current number with an old one.
- The app watches that file with `DispatchSource.makeFileSystemObjectSource` and re-renders on every change. As a safety net it also checks the file's modification time every 10 seconds.
- Alerts fire once per threshold per window; state persists in `UserDefaults` so restarts don't re-fire.

**No network calls. No daemons. No polling of Anthropic.** The app makes zero API requests against Anthropic — it only reads what your local Claude tools have already pulled. Tokenz consumes **zero quota**.

### Update cadence

Tokenz isn't a poller — it's a passive observer. The cadence comes entirely from your local Claude tools running the status-line hook:

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

### What Tokenz sees

Rate limits live on your Anthropic account, but Tokenz only learns about them through local tools that fire the status-line hook. Coverage by surface:

| Surface | Updates the menu bar? |
|---|---|
| Claude Code (CLI / IDE) | ✅ every assistant turn |
| Claude desktop app + Cowork (local agents) | ✅ inherits the same `statusLine` config from `~/.claude/settings.json` |
| Claude.ai web chat | ❌ nothing local runs |
| Claude mobile / iPad app | ❌ nothing local runs |

The good news: rate limits are account-wide, so whatever you burn through web chat or mobile is *visible to Tokenz as soon as the next Claude Code or Cowork turn fires.* The hook reports the current account-wide percentages, so consumption from other surfaces catches up with at most one assistant-turn of delay. If you only ever use claude.ai web chat, Tokenz won't be useful — it has nothing to react to.

## Reliability & limits

Tokenz is best-effort. A few caveats before you rely on it:

- **It only sees what your local Claude Code (or Cowork) sees.** If you only use claude.ai web or mobile, the status-line hook never fires, so the app has nothing to show.
- **It's at least one assistant turn behind live account state.** Structural, not a bug — see [Update cadence](#update-cadence).
- **Notifications can be missed.** Thresholds (70 / 85 / 95%) only fire when the app is running and a status-line update arrives that crosses them. Cross 85% via web chat while Tokenz is closed and you'll skip that alert — only the next unfired threshold counts.
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
- The app reads `usage.json` only if it is a small regular file: it opens
  the file without following symlinks and checks the open file before
  reading. The file and its directory are owner-only.
- Connect changes one entry in `~/.claude/settings.json` and nothing else. It
  saves a timestamped backup next to the file first, re-parses its own edit
  and refuses to write if anything other than `statusLine` would differ,
  refuses to touch a file that isn't valid JSON or that changed while it was
  working, and writes through symlinks so dotfile managers (stow, chezmoi,
  yadm) keep working.
- Backups are full copies of `settings.json`, so they contain whatever you
  keep in that file. They are owner-only, and only the newest five are kept.
- The app never asks for your Claude login and does not read or store
  tokens, the Keychain, or your conversations. Claude Code passes session
  details to every status line command; Tokenz keeps only the usage
  percentages, their reset times and the model name.
- Release builds use the hardened runtime and carry no debug entitlements.
- The only program the app ever starts is the status line command saved in
  `~/Library/Application Support/Tokenz/chained-statusline-command`. Connect
  writes your previous status line there if you had one, and removes the
  file if you didn't.
- The app currently runs **without** the macOS sandbox, because it has to
  edit `~/.claude/settings.json` and share an Application Support path with
  the `--statusline` process that Claude Code launches.
- The app is ad-hoc signed and not yet notarized, so macOS can't verify who
  built it. Check the SHA-256 on the release page, or build from source.

## Uninstall

1. Click the menu bar item, then **Disconnect from Claude Code**. This removes the `statusLine` entry from `~/.claude/settings.json`, or puts your previous status line back if you had one. Do this before deleting the app: otherwise Claude Code keeps trying to run a program that is no longer there.
2. Quit Tokenz.
3. Move `Tokenz.app` to the Trash.
4. Optional: `rm -rf ~/Library/Application\ Support/Tokenz`, and delete the `settings.json.tokenz-backup-*` files in `~/.claude`.

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

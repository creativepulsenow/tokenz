# Changelog

Each release's section below is also its release notes.

## 1.5.4

- **Fixes from a security review of the changes since 1.4.3.** Nothing serious was found. The rows for extra limits (shown only if Claude Code ever reports any) are stricter about their names, can't go backward or linger without a reset time, and can't imitate the two built-in rows.
- **A malformed extra row can no longer blank the display.**
- **Release pipeline tightened:** the job that signs and publishes no longer runs any project code, a release tag must be on `main`, and the check that shipped builds carry no entitlements is now complete.

## 1.5.3

- **No more "Data may be out of date" warning.** It appeared 90 seconds after the last Claude Code reply, which is most of the time you glance at the app, for a number that is almost always still right. The menu bar still marks an older number with a tilde, and the popover still says when it was last updated.

## 1.5.2

- **Removed the per-model section and the Fable note.** A split of usage by model is not the same as a model's own limit, and showing one invited that confusion. Tokenz shows limits only.
- **Still ready for a real Fable limit.** If Claude Code starts passing a per-model weekly limit to the status line, it appears as its own row, like the session and weekly ones.

## 1.5.1

- **The per-model section no longer looks like a limit.** It is now one bar split between the models, titled "Where your usage went", and it says since when it has been counting. In 1.5.0 it was a row of bars with percentages right under the real limits, which read as more limits.

## 1.5.0

- **This week by model.** The popover shows how your Claude Code usage on this Mac splits across models, for example Fable 62%, Opus 30%. It is an estimate from each session's own cost figures, and it starts counting from this version on.
- **Ready for per-model limits.** If Claude Code starts passing more limits to the status line (a separate Fable or Opus weekly limit, say), they appear as extra rows without an update.
- **A pointer for Fable.** While you are on Fable, the popover notes that Fable has its own weekly limit and where to find it (`/usage` in Claude Code), because Claude Code doesn't report that number to the status line today.

## 1.4.4

- **Built in the open.** This is the first release built by GitHub Actions from the tagged commit, with a signed provenance record you can check.
- No changes to how the app behaves.

## 1.4.3

- **The menu bar icon is now color-coded:** green under 60%, orange from 60%, red from 85%.
- **Alerts are more trustworthy:** no alert for a window that has already ended, and each threshold fires once per window.
- **Readings can't get lost or go stale:** fixes for canceled status line runs, expired windows, and sessions that haven't had their first reply yet.
- **Your own status line is visible:** if Tokenz runs one for you, the popover shows the command and lets you stop it.
- **Settings backups are private:** they now live in the app's own folder, owner-only, newest five kept.
- **Unit tests** cover the code that edits your settings and decides which reading to trust.

## 1.4.2

- **Apple Silicon only.** The Intel half of the app is gone. Intel Macs are not supported.

## 1.4.1

- **Accurate with several sessions open.** An idle Claude Code session can no longer overwrite the current number with an old one.
- **Fixes from a security review** of setup, the status line and file handling.
- **Cleaner build:** the app is stripped and no longer contains build-machine paths.

## 1.4.0

- **Renamed to Tokenz.** Earlier versions shipped as ClaudeMonitor.

## 1.3.0

- **One-click setup:** a Connect to Claude Code button replaces the install script. No Terminal, no Homebrew, no `jq`.
- **The app is its own status line command,** and an existing status line of your own keeps showing.
- **Hardened build:** hardened runtime on, debug entitlement removed.

## 1.2.0

- **The percentage stays visible while idle,** marked with a tilde, until the window resets.
- **Reset countdown** in the menu bar.

## 1.1.0

- First build packaged as a DMG.

## 1.0.0

- First working version.

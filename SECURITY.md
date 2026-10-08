# Security

## Reporting a vulnerability

Please report security problems privately through GitHub:
**Security → Report a vulnerability** on this repository
(https://github.com/creativepulsenow/tokenz/security/advisories/new).

Do not open a public issue for a vulnerability. You should get a reply
within a week.

## Supported versions

Only the latest release gets fixes.

## What Tokenz touches

- It reads the usage numbers Claude Code passes to its status line command.
- It edits one entry, `statusLine`, in `~/.claude/settings.json`, and only
  when you click Connect, Update Connection or Disconnect.
- It keeps its data in `~/Library/Application Support/Tokenz`.
- It makes no network calls.

Release builds are ad-hoc signed and not yet notarized. Check the SHA-256
on the release page, or build from source.

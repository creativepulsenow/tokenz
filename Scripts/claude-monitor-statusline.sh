#!/bin/bash
set -euo pipefail

# ClaudeMonitor Status Line Script
# Called by Claude Code after each assistant message.
# Reads JSON session data from stdin, writes usage data to a shared file
# for the menu bar app, and prints a one-line status for Claude Code.

# Data directory (~/Library/Application Support/ClaudeMonitor on macOS)
DATA_DIR="${HOME}/Library/Application Support/ClaudeMonitor"
DATA_FILE="${DATA_DIR}/usage.json"
TMP_FILE="${DATA_FILE}.tmp.$$"
mkdir -p "$DATA_DIR"

# Read stdin once (Claude Code only sends it once per call)
input=$(cat)

# Extract rate_limits and write atomically (tmp + mv).
# If jq fails or rate_limits is absent, leave the previous file alone.
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

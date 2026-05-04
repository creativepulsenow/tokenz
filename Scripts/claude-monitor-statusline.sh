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

# Always clean up the tmp file, however we exit.
trap 'rm -f "$TMP_FILE" 2>/dev/null || true' EXIT

# Read stdin once (Claude Code only sends it once per call)
input=$(cat)

# Project to ClaudeMonitor's schema and write atomically (tmp + mv).
# Always write — even when rate_limits is absent — so the app can distinguish
# "haven't received any data yet" from "received data but no rate limits in
# this Claude Code response" (the latter typically means a Free plan).
# The validation gate (`jq -e '.'`) ensures we only mv a syntactically valid
# JSON object into place; if the projection fails for any reason we keep the
# previous file untouched.
if echo "$input" | jq '{
        five_hour: (.rate_limits.five_hour // null),
        seven_day: (.rate_limits.seven_day // null),
        model:     (.model.display_name // null),
        updated_at: now
     }' > "$TMP_FILE" 2>/dev/null \
   && jq -e 'type == "object"' "$TMP_FILE" > /dev/null 2>&1; then
    mv -f "$TMP_FILE" "$DATA_FILE"
fi

# Print status line for Claude Code display
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null || true)
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null || true)

LIMITS=""
[ -n "$FIVE_H" ] && LIMITS="5h: $(printf '%.0f' "$FIVE_H")%"
[ -n "$WEEK" ] && LIMITS="${LIMITS:+$LIMITS | }7d: $(printf '%.0f' "$WEEK")%"

[ -n "$LIMITS" ] && echo "$LIMITS" || echo "..."

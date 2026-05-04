#!/bin/bash
# Gate 0: Verify that Claude Code's status line JSON contains rate_limits data.
# Run this BEFORE building the app. If it fails, the project is blocked.
#
# Usage:
#   chmod +x gate0-verify.sh
#   ./gate0-verify.sh
#
# Then open Claude Code and send any message. Come back and press Enter.

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
DEBUG_SCRIPT="${CLAUDE_DIR}/debug-statusline.sh"
DEBUG_OUTPUT="/tmp/claude-statusline-debug.json"
BACKUP="${SETTINGS}.gate0-bak"

echo "=== Gate 0: Verify rate_limits in status line JSON ==="
echo ""

# Check jq is available
if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is required. Install with: brew install jq"
  exit 1
fi

# Back up existing settings
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$BACKUP"
  echo "Backed up settings.json to ${BACKUP}"
  EXISTING_STATUSLINE=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
else
  EXISTING_STATUSLINE=""
fi

# Install debug status line script
mkdir -p "$CLAUDE_DIR"
cat > "$DEBUG_SCRIPT" <<'SCRIPT'
#!/bin/bash
input=$(cat)
echo "$input" > /tmp/claude-statusline-debug.json
echo "gate0 captured"
SCRIPT
chmod +x "$DEBUG_SCRIPT"

# Wire it into settings
if [ -f "$SETTINGS" ]; then
  TMP=$(mktemp)
  jq --arg cmd "$DEBUG_SCRIPT" '.statusLine = {type: "command", command: $cmd}' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
else
  cat > "$SETTINGS" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "${DEBUG_SCRIPT}"
  }
}
EOF
fi

echo "Debug status line installed."
echo ""
echo "NOW: Open Claude Code (or restart it) and send any message."
echo "     Then come back here and press Enter."
echo ""
read -r -p "Press Enter after sending a Claude Code message... "

# Check the output
if [ ! -f "$DEBUG_OUTPUT" ]; then
  echo ""
  echo "FAIL: ${DEBUG_OUTPUT} was not created."
  echo "Make sure Claude Code is running and you sent a message after installing this script."
  echo "You may need to restart Claude Code for the status line change to take effect."
  # Restore backup
  [ -f "$BACKUP" ] && mv "$BACKUP" "$SETTINGS"
  rm -f "$DEBUG_SCRIPT"
  exit 1
fi

echo ""
echo "=== Captured JSON (relevant fields): ==="
echo ""

# Check for rate_limits
HAS_RATE_LIMITS=$(jq -e '.rate_limits' "$DEBUG_OUTPUT" 2>/dev/null && echo "yes" || echo "no")

if [ "$HAS_RATE_LIMITS" = "no" ]; then
  echo "WARNING: rate_limits field is ABSENT from the JSON."
  echo ""
  echo "This can happen if:"
  echo "  1. This was the first message in the session (rate_limits appears after the first API response)"
  echo "  2. Your account is not Pro/Max (rate_limits is only for subscribers)"
  echo "  3. Claude Code version is too old"
  echo ""
  echo "Try sending another message and running this check again."
  echo ""
  echo "Full JSON dump:"
  jq '.' "$DEBUG_OUTPUT"
else
  echo "rate_limits found!"
  echo ""
  jq '{
    rate_limits: .rate_limits,
    model: .model,
    version: .version
  }' "$DEBUG_OUTPUT"

  # Verify specific fields
  FIVE_H=$(jq -r '.rate_limits.five_hour.used_percentage // "MISSING"' "$DEBUG_OUTPUT")
  FIVE_R=$(jq -r '.rate_limits.five_hour.resets_at // "MISSING"' "$DEBUG_OUTPUT")
  SEVEN_D=$(jq -r '.rate_limits.seven_day.used_percentage // "MISSING"' "$DEBUG_OUTPUT")
  SEVEN_R=$(jq -r '.rate_limits.seven_day.resets_at // "MISSING"' "$DEBUG_OUTPUT")

  echo ""
  echo "=== Field Check ==="
  echo "five_hour.used_percentage: ${FIVE_H}"
  echo "five_hour.resets_at:       ${FIVE_R}"
  echo "seven_day.used_percentage: ${SEVEN_D}"
  echo "seven_day.resets_at:       ${SEVEN_R}"

  if [ "$FIVE_H" != "MISSING" ] && [ "$FIVE_R" != "MISSING" ]; then
    echo ""
    echo "PASS: Gate 0 verified. All required fields present."
    echo "You are clear to build."
  else
    echo ""
    echo "PARTIAL: Some fields are missing. Check if your session window has started."
    echo "The fields may appear after more interaction."
  fi
fi

# Restore original settings
if [ -f "$BACKUP" ]; then
  mv "$BACKUP" "$SETTINGS"
  echo ""
  echo "Restored original settings.json."
elif [ -n "$EXISTING_STATUSLINE" ]; then
  echo ""
  echo "NOTE: Your original statusLine was: ${EXISTING_STATUSLINE}"
fi

# Cleanup
rm -f "$DEBUG_SCRIPT" "$DEBUG_OUTPUT"

echo ""
echo "Gate 0 complete. Debug script and output cleaned up."

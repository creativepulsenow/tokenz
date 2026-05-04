#!/bin/bash
set -euo pipefail

# ClaudeMonitor Installer
# Installs the status line script and merges with existing Claude Code settings.

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_SRC="${SCRIPT_DIR}/claude-monitor-statusline.sh"
SCRIPT_DEST="${CLAUDE_DIR}/claude-monitor-statusline.sh"

echo "=== ClaudeMonitor Installer ==="
echo ""

# Check prerequisites
if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is required. Install with: brew install jq"
  exit 1
fi

if [ ! -f "$SCRIPT_SRC" ]; then
  echo "ERROR: Cannot find claude-monitor-statusline.sh in ${SCRIPT_DIR}"
  exit 1
fi

# Install the status line script
mkdir -p "$CLAUDE_DIR"
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
echo "Installed status line script to ${SCRIPT_DEST}"

# Handle settings.json
if [ ! -f "$SETTINGS" ]; then
  # No settings file exists, create one
  cat > "$SETTINGS" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "${SCRIPT_DEST}"
  }
}
EOF
  echo "Created new settings.json with status line config."
  echo ""
  echo "Done! Restart Claude Code to activate."
  exit 0
fi

# Settings file exists, check for existing statusLine
EXISTING=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)

if [ -z "$EXISTING" ]; then
  # No statusLine configured, merge ours in
  TMP=$(mktemp)
  jq --arg cmd "$SCRIPT_DEST" \
     '. + {statusLine: {type: "command", command: $cmd}}' \
     "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  echo "Added status line to existing settings.json."
  echo ""
  echo "Done! Restart Claude Code to activate."

elif [ "$EXISTING" = "$SCRIPT_DEST" ]; then
  echo "Status line already installed. Script updated, no config change needed."
  echo ""
  echo "Done! Restart Claude Code if the script changed."

else
  echo ""
  echo "WARNING: You already have a status line configured:"
  echo "  ${EXISTING}"
  echo ""
  echo "ClaudeMonitor's status line is at:"
  echo "  ${SCRIPT_DEST}"
  echo ""
  echo "To use both, edit your existing script to chain ours."
  echo "Add this near the top of your existing script, before reading stdin:"
  echo ""
  echo '  input=$(cat)'
  echo "  echo \"\$input\" | ${SCRIPT_DEST} > /dev/null"
  echo '  # Then continue your existing logic using $input'
  echo ""
  echo "Or replace your existing config manually in:"
  echo "  ${SETTINGS}"
  echo ""
  echo "To replace automatically, run:"
  echo "  jq --arg cmd \"${SCRIPT_DEST}\" '.statusLine.command = \$cmd' \"${SETTINGS}\" > /tmp/settings-tmp.json && mv /tmp/settings-tmp.json \"${SETTINGS}\""
  exit 1
fi

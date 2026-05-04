#!/bin/bash
set -euo pipefail

# make-dmg.sh
# Builds a redistributable .dmg for ClaudeMonitor.
#
# Usage:
#   ./Scripts/make-dmg.sh                      # auto-rebuilds via xcodebuild
#   ./Scripts/make-dmg.sh /path/to/MyBuild.app # uses an existing .app
#
# Output: build/ClaudeMonitor-<version>.dmg

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="ClaudeMonitor"
DERIVED="${REPO_ROOT}/build/xcode-derived"
APP_DEFAULT="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
APP_PATH="${1:-${APP_DEFAULT}}"

# Build if needed
if [ ! -d "$APP_PATH" ] || [ -z "${1:-}" ]; then
  echo "==> Building Release configuration (universal: arm64 + x86_64)"
  xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build > /dev/null
  APP_PATH="${APP_DEFAULT}"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: $APP_PATH does not exist"
  exit 1
fi

# Read version from the app's Info.plist (single source of truth)
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")
echo "==> Packaging ${APP_NAME} ${VERSION}"

STAGING="${REPO_ROOT}/build/dmg-staging"
DMG_OUT="${REPO_ROOT}/build/${APP_NAME}-${VERSION}.dmg"

# Clean previous artifacts
rm -rf "$STAGING" "$DMG_OUT"
mkdir -p "$STAGING"

# Copy the app
echo "==> Staging files"
cp -R "$APP_PATH" "$STAGING/"

# Drag-to-install affordance
ln -s /Applications "$STAGING/Applications"

# Bundled install script for the Claude Code status line bridge
cp Scripts/install.sh "$STAGING/install.sh"
chmod +x "$STAGING/install.sh"
# Status line script too, since install.sh expects it as a sibling
cp Scripts/claude-monitor-statusline.sh "$STAGING/claude-monitor-statusline.sh"
chmod +x "$STAGING/claude-monitor-statusline.sh"

# README inside the DMG
cat > "$STAGING/README.txt" <<EOF
ClaudeMonitor ${VERSION}
$(printf '=%.0s' $(seq 1 $((13 + ${#VERSION}))))

A native macOS menu bar app that shows your Claude usage limits.

INSTALL
-------
1. Drag ClaudeMonitor.app to the Applications shortcut on the right.
   (SMAppService and notification permissions both require /Applications.)

2. Open Terminal in this DMG window and run:
       ./install.sh
   This wires up the Claude Code status line bridge (non-destructive
   merge into ~/.claude/settings.json).

3. Quit and relaunch Claude Code (Cmd+Q, then reopen).

4. Send any message in Claude Code so it pipes the first batch of
   usage data to ClaudeMonitor.

5. Launch ClaudeMonitor.app from /Applications.

FIRST LAUNCH (Gatekeeper)
-------------------------
The app is ad-hoc signed (no paid Apple Developer ID), so the first
time you open it, macOS will say "ClaudeMonitor cannot be opened
because the developer cannot be verified."

To open it once and tell macOS to trust it from then on:
  - Right-click (or Control-click) ClaudeMonitor.app in /Applications
  - Choose "Open"
  - Click "Open" in the dialog that appears

After that, ClaudeMonitor launches normally.

REQUIREMENTS
------------
  - macOS 14.0 (Sonoma) or later
  - Claude Code installed
  - Claude.ai Pro or Max plan (rate-limit data only appears on these tiers)
  - jq (install with: brew install jq)

UNINSTALL
---------
  - Quit ClaudeMonitor.
  - Drag ClaudeMonitor.app from /Applications to the Trash.
  - Edit ~/.claude/settings.json to remove the "statusLine" entry
    (or restore your previous one).
  - Optional: rm -rf ~/Library/Application\\ Support/ClaudeMonitor

PRIVACY
-------
Everything stays on your machine. No network calls. No telemetry.
Inputs are sanitized at the boundary so a misbehaving cohabitant can't
crash or spoof the UI.

Repo:    https://github.com/creativepulsenow/claude-usage-taskbar-macos
License: MIT
EOF

# Build the DMG
echo "==> Creating DMG"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_OUT" > /dev/null

# Cleanup
rm -rf "$STAGING"

# Report
SIZE=$(du -h "$DMG_OUT" | cut -f1)
echo "==> Built ${DMG_OUT} (${SIZE})"
echo ""
shasum -a 256 "$DMG_OUT"

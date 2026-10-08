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

# README inside the DMG
cat > "$STAGING/README.txt" <<EOF
ClaudeMonitor ${VERSION}
$(printf '=%.0s' $(seq 1 $((13 + ${#VERSION}))))

A native macOS menu bar app that shows your Claude usage limits.

INSTALL
-------
1. Drag ClaudeMonitor.app to the Applications shortcut on the right.

2. Open ClaudeMonitor from /Applications (see FIRST LAUNCH below).

3. Click the new menu bar item, then "Connect to Claude Code".
   This adds a statusLine entry to ~/.claude/settings.json. A backup
   of the file is saved first, and an existing status line of your
   own keeps showing.

4. Quit and relaunch Claude Code (Cmd+Q, then reopen), then send any
   message so it reports the first batch of usage data.

FIRST LAUNCH (Gatekeeper)
-------------------------
The app is ad-hoc signed (no paid Apple Developer ID), so the first
time you open it, macOS will refuse and say it could not verify the
app.

To open it once and tell macOS to trust it from then on:
  - Open System Settings > Privacy & Security
  - Scroll down to the message about ClaudeMonitor
  - Click "Open Anyway" and confirm
  (On macOS 14 you can instead right-click the app and choose "Open".)

After that, ClaudeMonitor launches normally.

REQUIREMENTS
------------
  - macOS 14.0 (Sonoma) or later
  - Claude Code installed
  - Claude.ai Pro or Max plan (rate-limit data only appears on these tiers)

UNINSTALL
---------
  - Click the menu bar item, then "Disconnect from Claude Code".
  - Quit ClaudeMonitor.
  - Drag ClaudeMonitor.app from /Applications to the Trash.
  - Optional: rm -rf ~/Library/Application\\ Support/ClaudeMonitor

PRIVACY
-------
Everything stays on your machine. No network calls. No telemetry.
No account sign-in: the app never sees your Claude login.

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

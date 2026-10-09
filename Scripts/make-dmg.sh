#!/bin/bash
set -euo pipefail

# make-dmg.sh
# Builds a redistributable .dmg for Tokenz.
#
# Usage:
#   ./Scripts/make-dmg.sh                      # auto-rebuilds via xcodebuild
#   ./Scripts/make-dmg.sh /path/to/MyBuild.app # uses an existing .app
#
# Output: build/Tokenz-<version>.dmg

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Tokenz"
DERIVED="${REPO_ROOT}/build/xcode-derived"
APP_DEFAULT="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
APP_PATH="${1:-${APP_DEFAULT}}"

# A release must be buildable from what is committed. Refuse a dirty tree
# unless explicitly overridden (ALLOW_DIRTY=1) for local test builds.
if [ -z "${ALLOW_DIRTY:-}" ] && [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree has uncommitted changes. Commit first, or set ALLOW_DIRTY=1."
  exit 1
fi

# Package an existing .app if one was given; it has to exist.
if [ -n "${1:-}" ] && [ ! -d "$1" ]; then
  echo "ERROR: $1 does not exist"
  exit 1
fi

# Otherwise build. Always from scratch, so nothing stale from an earlier
# build can end up in the bundle.
if [ -z "${1:-}" ]; then
  echo "==> Building Release configuration (Apple Silicon)"
  rm -rf "${DERIVED}/Build"
  xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED}" \
    ARCHS="arm64" \
    ONLY_ACTIVE_ARCH=NO \
    build > /dev/null
  APP_PATH="${APP_DEFAULT}"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: $APP_PATH does not exist"
  exit 1
fi

# Checks every shipped build must pass.
BINARY="${APP_PATH}/Contents/MacOS/${APP_NAME}"
if [ "$(lipo -archs "$BINARY")" != "arm64" ]; then
  echo "ERROR: expected an Apple Silicon only binary, got: $(lipo -archs "$BINARY")"; exit 1
fi
echo "==> Verifying the build"
codesign --verify --deep --strict "$APP_PATH"
# Capture first: with pipefail, `grep -q` closing the pipe early can make the
# left side fail and turn a pass into a false alarm.
SIGNATURE="$(codesign -dv "$APP_PATH" 2>&1)"
ENTITLEMENTS="$(codesign -d --entitlements - "$APP_PATH" 2>/dev/null || true)"
case "$SIGNATURE" in
  *flags=*runtime*) ;;
  *) echo "ERROR: hardened runtime is not enabled"; exit 1 ;;
esac
case "$ENTITLEMENTS" in
  *"<key>"*) echo "ERROR: the app carries entitlements; shipped builds must have none"; exit 1 ;;
esac
if LC_ALL=C grep -aq '/Users/' "$BINARY"; then
  echo "ERROR: the binary contains local /Users/ paths"; exit 1
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
Tokenz ${VERSION}
$(printf '=%.0s' $(seq 1 $((7 + ${#VERSION}))))

A native macOS menu bar app that shows your Claude usage limits.

INSTALL
-------
1. Drag Tokenz.app to the Applications shortcut on the right.

2. Open Tokenz from /Applications (see FIRST LAUNCH below).

3. Click the new menu bar item, then "Connect to Claude Code".
   This adds a statusLine entry to ~/.claude/settings.json. Tokenz
   keeps a backup of the file, and an existing status line of your
   own keeps showing.

4. Send any message in Claude Code so it reports the first batch of
   usage data. (If nothing shows up, quit and relaunch Claude Code.)

FIRST LAUNCH (Gatekeeper)
-------------------------
The app is ad-hoc signed (no paid Apple Developer ID), so the first
time you open it, macOS will refuse and say it could not verify the
app.

To open it once and tell macOS to trust it from then on:
  - Open System Settings > Privacy & Security
  - Scroll down to the message about Tokenz
  - Click "Open Anyway" and confirm
  (On macOS 14 you can instead right-click the app and choose "Open".)

After that, Tokenz launches normally.

REQUIREMENTS
------------
  - A Mac with Apple Silicon (M1 or later)
  - macOS 14.0 (Sonoma) or later
  - Claude Code installed
  - Claude.ai Pro or Max plan (rate-limit data only appears on these tiers)

UNINSTALL
---------
  - Click the menu bar item, then "Disconnect from Claude Code".
    Do this first, or Claude Code keeps trying to run the deleted app.
  - Quit Tokenz.
  - Drag Tokenz.app from /Applications to the Trash.
  - Optional: rm -rf ~/Library/Application\\ Support/Tokenz

PRIVACY
-------
Everything stays on your machine. No network calls. No telemetry.
No account sign-in: the app never sees your Claude login.

Repo:    https://github.com/creativepulsenow/tokenz
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

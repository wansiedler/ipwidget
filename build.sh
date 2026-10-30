#!/bin/zsh
# Build IPWidget.app, install to ~/Applications, (re)load launchd agent.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=IPWidget
BUILD=build
APP="$BUILD/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
LABEL=com.wansiedler.ipwidget
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

rm -rf "./${BUILD:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework MapKit -framework Network -framework CoreWLAN -framework UserNotifications -framework Carbon \
  *.swift -o "$APP/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :IPWRepoPath string $(pwd)" "$APP/Contents/Info.plist"
# Sign with a stable identity when available. Notification Center matches an app to
# its notification record by code-signing requirement; an ad-hoc signature yields a
# cdhash requirement that changes on every build, so the banner loses the app icon.
SIGN_ID="${IPW_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')}"
codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP"
echo "signed as: ${SIGN_ID:-ad-hoc}"

# Stop running instance / agent
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/IPWidget"
rm -rf "${INSTALL_DIR:?}/${APP_NAME:?}.app"
cp -R "$APP" "$INSTALL_DIR/"
cp "$LABEL.plist" "$AGENT"
# Keep a single LaunchServices registration for the bundle id: Notification Center
# resolves the app icon by bundle id and may pick a stale copy otherwise.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$(pwd)/$APP" 2>/dev/null || true
"$LSREG" -f "$INSTALL_DIR/$APP_NAME.app"

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "installed: $INSTALL_DIR/$APP_NAME.app"
echo "agent:     $AGENT"

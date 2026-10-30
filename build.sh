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
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework MapKit -framework Network -framework CoreWLAN -framework UserNotifications -framework Carbon \
  *.swift -o "$APP/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :IPWRepoPath string $(pwd)" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

# Stop running instance / agent
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/IPWidget"
rm -rf "${INSTALL_DIR:?}/${APP_NAME:?}.app"
cp -R "$APP" "$INSTALL_DIR/"
cp "$LABEL.plist" "$AGENT"
# Register the bundle with LaunchServices so notifications/attribution work
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/$APP_NAME.app"

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "installed: $INSTALL_DIR/$APP_NAME.app"
echo "agent:     $AGENT"

#!/bin/bash
# Builds PIM Bridge and (re)installs it as a LaunchAgent.
#
# Signed with the self-signed "MouseRemap Local Signing" identity when it's in the
# login keychain, so the Reminders, Calendars and Contacts permissions survive
# rebuilds. Without it the build is signed ad hoc and macOS asks again each time.

set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.ianneub.pim-bridge
APP="$HOME/Applications/PIMBridge.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "Building..."
mkdir -p "$BUILD/PIMBridge.app/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -o "$BUILD/PIMBridge.app/Contents/MacOS/PIMBridge" Common.swift Reminders.swift Calendar.swift Contacts.swift main.swift
cp Info.plist "$BUILD/PIMBridge.app/Contents/Info.plist"

IDENTITY="MouseRemap Local Signing"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "warning: no \"$IDENTITY\" identity; signing ad hoc (permissions reset each rebuild)" >&2
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" --identifier "$LABEL" "$BUILD/PIMBridge.app"

echo "Installing $APP..."
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
mv "$BUILD/PIMBridge.app" "$APP"
sed "s|@HOME@|$HOME|g" "$LABEL.plist" >"$PLIST"

# bootout returns before the old job is fully gone; retry until it is.
for _ in 1 2 3 4 5; do
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break
  sleep 1
done
launchctl print "$DOMAIN/$LABEL" >/dev/null

echo "Running. Log: ~/Library/Logs/PIMBridge.log"

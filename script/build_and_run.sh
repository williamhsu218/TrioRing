#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--build-only|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$PROJECT_DIR"
APP_NAME="TrioRing"
BUNDLE_ID="com.willhsu.ring-a-bar"
SIGN_IDENTITY="${TRIORING_SIGN_IDENTITY:--}"
SIGN_TIMESTAMP="${TRIORING_SIGN_TIMESTAMP:-none}"
case "$SIGN_TIMESTAMP" in
  none) TIMESTAMP_FLAG="--timestamp=none" ;;
  secure) TIMESTAMP_FLAG="--timestamp" ;;
  *) echo "TRIORING_SIGN_TIMESTAMP must be 'none' or 'secure'." >&2; exit 2 ;;
esac
DIST_DIR="$PROJECT_DIR/dist"
mkdir -p "$DIST_DIR"

if [[ "$MODE" != "--build-only" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x Ring-a-Bar >/dev/null 2>&1 || true
fi

swift build -c release --product "$APP_NAME"
swift build -c release --product TrioRingPowerHelper
swift build -c release --product TrioRingLauncher
BUILD_DIR="$(swift build -c release --show-bin-path)"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.staging.XXXXXX")"
# Resolve and check every cleanup target before deleting a generated tree.
verify_staging() {
  [[ -n "${STAGING_DIR:-}" && "$STAGING_DIR" == "$DIST_DIR"/.staging.* && ! -L "$STAGING_DIR" \
    && "$(cd "$STAGING_DIR" && pwd -P)" == "$STAGING_DIR" ]]
}
verify_staging || { echo "Unexpected staging path" >&2; exit 1; }
trap 'if verify_staging; then rm -rf -- "${STAGING_DIR:?}"; fi' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$STAGED_APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
cp -R Resources/zh-Hans.lproj "$STAGED_APP/Contents/Resources/"
cp -R Resources/ThirdParty "$STAGED_APP/Contents/Resources/"
xcrun swiftc Sources/RingABar/StatusIconGeometry.swift script/make_icon.swift -o "$STAGING_DIR/make-icon"
"$STAGING_DIR/make-icon" "$STAGING_DIR/AppIcon.iconset"
iconutil -c icns "$STAGING_DIR/AppIcon.iconset" -o "$STAGED_APP/Contents/Resources/AppIcon.icns"
plutil -lint "$STAGED_APP/Contents/Info.plist" Resources/TrioRing.entitlements >/dev/null

# Always install Helpers
mkdir -p "$STAGED_APP/Contents/Helpers" "$STAGED_APP/Contents/Library/LaunchDaemons"
mkdir -p "$STAGED_APP/Contents/Library/LoginItems/TrioRingLauncher.app/Contents/MacOS"
cp "$BUILD_DIR/TrioRingPowerHelper" "$STAGED_APP/Contents/Helpers/"
cp "$BUILD_DIR/TrioRingLauncher" "$STAGED_APP/Contents/Library/LoginItems/TrioRingLauncher.app/Contents/MacOS/TrioRingLauncher"
# Create a minimal Info.plist for the launcher
cat <<EOF > "$STAGED_APP/Contents/Library/LoginItems/TrioRingLauncher.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID.Launcher</string>
    <key>CFBundleName</key>
    <string>TrioRingLauncher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
cp "Resources/$BUNDLE_ID.PowerMode.plist" "$STAGED_APP/Contents/Library/LaunchDaemons/"
plutil -lint "$STAGED_APP/Contents/Library/LaunchDaemons/$BUNDLE_ID.PowerMode.plist" >/dev/null

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID.PowerMode" --options runtime "$TIMESTAMP_FLAG" \
    "$STAGED_APP/Contents/Helpers/TrioRingPowerHelper"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID.Launcher" --options runtime "$TIMESTAMP_FLAG" \
    "$STAGED_APP/Contents/Library/LoginItems/TrioRingLauncher.app"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime "$TIMESTAMP_FLAG" \
    --entitlements Resources/TrioRing.entitlements "$STAGED_APP"
else
  codesign --force --sign - --options runtime \
    "$STAGED_APP/Contents/Helpers/TrioRingPowerHelper"
  codesign --force --sign - --options runtime \
    "$STAGED_APP/Contents/Library/LoginItems/TrioRingLauncher.app"
  codesign --force --sign - --options runtime \
    --entitlements Resources/TrioRing.entitlements "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
[[ "$APP_BUNDLE" == "$PROJECT_DIR/dist/TrioRing.app" && ! -L "$APP_BUNDLE" \
  && "$(cd "$DIST_DIR" && pwd -P)" == "$DIST_DIR" \
  && "$STAGED_APP" == "$STAGING_DIR/TrioRing.app" && ! -L "$STAGED_APP" \
  && "$(cd "$STAGED_APP" && pwd -P)" == "$STAGED_APP" ]] \
  || { echo "Unexpected app bundle path" >&2; exit 1; }
rm -rf -- "${APP_BUNDLE:?}"
mv -- "${STAGED_APP:?}" "${APP_BUNDLE:?}"
echo "$APP_BUNDLE"

case "$MODE" in
  --build-only) ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --verify)
    open -n "$APP_BUNDLE"
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --logs|--telemetry)
    open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  run) open -n "$APP_BUNDLE" ;;
esac

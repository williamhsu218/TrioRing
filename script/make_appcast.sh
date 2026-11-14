#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" != 2 ]]; then
  echo "Usage: $0 path/to/Sparkle/bin path/to/TrioRing-<version>-arm64.dmg" >&2
  exit 2
fi
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SPARKLE_BIN="$(cd "$1" && pwd -P)"
DMG="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
ACCOUNT=com.willhsu.ring-a-bar
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PROJECT_DIR/Resources/Info.plist")
[[ "$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)" == "$PUBLIC_KEY" ]] || {
  echo "The local Sparkle key does not match TrioRing's public key." >&2
  exit 1
}

STAGING="$(mktemp -d)"
MOUNT="$STAGING/image"
mkdir "$MOUNT"
cleanup() {
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  rm -rf -- "$STAGING"
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" >/dev/null
APP="$MOUNT/TrioRing.app"
PLIST="$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")
MINIMUM=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ && "$MINIMUM" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]
[[ "$(basename "$DMG")" == "TrioRing-$VERSION-arm64.dmg" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST")" == "$PUBLIC_KEY" ]]

SIGNATURE=$("$SPARKLE_BIN/sign_update" --account "$ACCOUNT" -p "$DMG")
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" --verify "$DMG" "$SIGNATURE" >&2
SIZE=$(stat -f %z "$DMG")
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
RELEASE="https://github.com/williamhsu218/TrioRing/releases"
cat > "$STAGING/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>TrioRing Updates</title>
    <link>$RELEASE</link>
    <description>Updates for TrioRing on macOS.</description>
    <item>
      <title>TrioRing $VERSION</title>
      <link>$RELEASE/tag/v$VERSION</link>
      <description>See the GitHub release for what's new.</description>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <enclosure url="$RELEASE/download/v$VERSION/TrioRing-$VERSION-arm64.dmg"
                 length="$SIZE" type="application/octet-stream" sparkle:edSignature="$SIGNATURE" />
    </item>
  </channel>
</rss>
EOF
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" "$STAGING/appcast.xml" >&2
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" --verify "$STAGING/appcast.xml" >&2
cat "$STAGING/appcast.xml"

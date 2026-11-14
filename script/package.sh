#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/dist/TrioRing.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
codesign --verify --strict "$APP_BUNDLE"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/dist/.dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_BUNDLE" "$STAGING_DIR/TrioRing.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "TrioRing $VERSION" -srcfolder "$STAGING_DIR" -ov -format UDZO "$PROJECT_DIR/dist/TrioRing-$VERSION-arm64.dmg"

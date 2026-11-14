#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="TrioRing"
SOURCE_APP="$PROJECT_DIR/dist/$APP_NAME.app"
DESTINATION="/Applications/$APP_NAME.app"
STAGED_APP="/Applications/.$APP_NAME.install.$$.app"
BACKUP_DIR="$PROJECT_DIR/dist/rollback"
PREVIOUS="$DESTINATION"
LEGACY_APP="/Applications/Ring-a-Bar.app"

# Reject symlinks and noncanonical parents before moving or removing bundles.
verify_path() {
  local target="${1:?}"
  [[ "$target" == /* && ! -L "$target" \
    && "$(cd "$(dirname "$target")" && pwd -P)/$(basename "$target")" == "$target" ]]
}
verify_install_paths() {
  [[ "$DESTINATION" == "/Applications/TrioRing.app" \
    && "$STAGED_APP" == "/Applications/.TrioRing.install.$$.app" ]] \
    && verify_path "$DESTINATION" && verify_path "$STAGED_APP"
}
cleanup() {
  if [[ -e "$STAGED_APP" ]] && verify_install_paths; then
    rm -rf -- "${STAGED_APP:?}"
  fi
}

stop_app() {
  local process_name="$1"
  local attempt
  pkill -x "$process_name" >/dev/null 2>&1 || true
  for ((attempt = 0; attempt < 30; attempt++)); do
    if ! pgrep -x "$process_name" >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done
  echo "$process_name is still running; the installed app was left in place." >&2
  return 1
}

verify_path "$SOURCE_APP"
verify_install_paths
[[ ! -e "$STAGED_APP" ]] || { echo "Install staging path already exists" >&2; exit 1; }
codesign --verify --deep --strict "$SOURCE_APP"
trap cleanup EXIT
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
stop_app "$APP_NAME"
if [[ ! -e "$PREVIOUS" && -d "$LEGACY_APP" ]] &&
   [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$LEGACY_APP/Contents/Info.plist")" == "com.willhsu.ring-a-bar" ]]; then
  PREVIOUS="$LEGACY_APP"
  stop_app Ring-a-Bar
fi
if [[ -e "$PREVIOUS" ]]; then
  mkdir -p "$BACKUP_DIR"
  PREVIOUS_NAME="$(basename "$PREVIOUS" .app)"
  BACKUP="$BACKUP_DIR/$PREVIOUS_NAME-$(date +%Y%m%d-%H%M%S)-$$.app"
  [[ "$PREVIOUS" == "$DESTINATION" || "$PREVIOUS" == "$LEGACY_APP" ]]
  [[ "$BACKUP" == "$BACKUP_DIR"/"$PREVIOUS_NAME"-*.app && ! -e "$BACKUP" ]]
  verify_path "$PREVIOUS" && verify_path "$BACKUP" && verify_install_paths \
    || { echo "Unexpected install or backup path" >&2; exit 1; }
  mv -- "${PREVIOUS:?}" "${BACKUP:?}"
  if ! mv -- "${STAGED_APP:?}" "${DESTINATION:?}"; then
    verify_path "$BACKUP" && verify_path "$PREVIOUS" \
      || { echo "Unexpected rollback path; backup left in place" >&2; exit 1; }
    mv -- "${BACKUP:?}" "${PREVIOUS:?}"
    open "$PREVIOUS"
    exit 1
  fi
  echo "Previous app backed up to: $BACKUP"
else
  verify_install_paths
  mv -- "${STAGED_APP:?}" "${DESTINATION:?}"
fi
if ! open "$DESTINATION"; then
  sleep 0.3
  open "$DESTINATION"
fi
echo "$DESTINATION"

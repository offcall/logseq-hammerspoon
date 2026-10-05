#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="$HOME/.hammerspoon"
TARGET="$CONFIG_DIR/init.lua"

mkdir -p "$CONFIG_DIR"
if [[ -e "$TARGET" ]]; then
    BACKUP=$(mktemp "$CONFIG_DIR/init.lua.backup.XXXXXX")
    cp -p "$TARGET" "$BACKUP"
    printf 'Previous config saved to %s\n' "$BACKUP"
fi

cp "$SCRIPT_DIR/logseq_capture.lua" "$TARGET"
printf 'Installed %s\n' "$TARGET"

# Standard AppleScript commands work without hs.allowAppleScript(true).
osascript <<'APPLESCRIPT'
if application "Hammerspoon" is running then
    tell application "Hammerspoon" to quit
    repeat with attempt from 1 to 100
        if not (application "Hammerspoon" is running) then exit repeat
        delay 0.1
    end repeat
    if application "Hammerspoon" is running then
        error "Hammerspoon did not quit; config installed but restart failed."
    end if
end if
APPLESCRIPT

open -a Hammerspoon
printf 'Hammerspoon started with the updated config.\n'

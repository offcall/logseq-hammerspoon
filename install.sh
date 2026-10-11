#!/bin/bash
# Install or update logseq-hammerspoon.
#
#   curl -fsSL https://raw.githubusercontent.com/offcall/logseq-hammerspoon/main/install.sh | bash
#
# or ./install.sh from a clone. Optional: LOGSEQ_GRAPH and LOGSEQ_DASHBOARD
# answer the first-run questions without a prompt.
set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/offcall/logseq-hammerspoon/main"
CONFIG_DIR="$HOME/.hammerspoon"
SCRIPT="$CONFIG_DIR/logseq_capture.lua"
USER_CONFIG="$CONFIG_DIR/logseq_capture_config.lua"
INIT="$CONFIG_DIR/init.lua"
LOAD_LINE='require("logseq_capture")'
# Header line of the script; marks an init.lua that is a full copy of it.
OLD_COPY_MARKER='Logseq Capture + Today panel for Hammerspoon'

backup() {
    local backup
    backup=$(mktemp "$1.backup.XXXXXX")
    cp -p "$1" "$backup"
    printf 'Previous %s saved to %s\n' "$(basename "$1")" "$backup"
}

ask() {
    local answer=""
    # The prompt goes to the terminal: stdout is captured, stdin may be curl.
    if { : </dev/tty; } 2>/dev/null; then
        read -r -p "$1" answer </dev/tty 2>/dev/tty || true
    fi
    printf '%s' "$answer"
}

lua_string() {
    local value=${1//\\/\\\\}
    printf '"%s"' "${value//\"/\\\"}"
}

# Wrapped in main so a partial download (curl | bash) never runs.
main() {
    mkdir -p "$CONFIG_DIR"

    # 1. User config: created once, kept on updates.
    if [[ ! -e "$USER_CONFIG" ]]; then
        GRAPH=${LOGSEQ_GRAPH:-$(ask 'Logseq graph name: ')}
        if [[ -z "$GRAPH" ]]; then
            printf 'No graph name. Re-run with LOGSEQ_GRAPH="<graph>".\n' >&2
            exit 1
        fi

        if [[ -n "${LOGSEQ_DASHBOARD+set}" ]]; then
            DASHBOARD=$LOGSEQ_DASHBOARD
        else
            DASHBOARD=$(ask 'Page for the panel'\''s top-right button (empty = no button): ')
        fi

        CLI=$("${SHELL:-/bin/zsh}" -lic 'command -v logseq' </dev/null 2>/dev/null | tail -n 1 || true)
        if [[ "$CLI" != /* ]]; then
            CLI="$HOME/.local/bin/logseq"
            printf 'Logseq CLI not found on PATH; using %s (edit %s if wrong).\n' "$CLI" "$USER_CONFIG"
        fi

        if [[ -n "$DASHBOARD" ]]; then
            DASHBOARD_VALUE=$(lua_string "$DASHBOARD")
        else
            DASHBOARD_VALUE=false
        fi

        cat >"$USER_CONFIG" <<EOF
-- logseq-hammerspoon settings; kept when install.sh updates the script.
return {
    logseq = $(lua_string "$CLI"),
    graph = $(lua_string "$GRAPH"),
    dashboardPage = $DASHBOARD_VALUE,   -- false hides the button
    -- openHotkey = { {"cmd", "alt"}, "L" },
}
EOF
        printf 'Created %s\n' "$USER_CONFIG"
    fi

    # 2. Script: copy from a clone, otherwise download.
    SOURCE_DIR=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    fi

    if [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/logseq_capture.lua" ]]; then
        cp "$SOURCE_DIR/logseq_capture.lua" "$SCRIPT.tmp"
    else
        curl -fsSL "$RAW_URL/logseq_capture.lua" -o "$SCRIPT.tmp"
    fi
    mv "$SCRIPT.tmp" "$SCRIPT"
    printf 'Installed %s\n' "$SCRIPT"

    # 3. init.lua loads the script.
    if [[ -e "$INIT" ]] && grep -qF "$OLD_COPY_MARKER" "$INIT"; then
        backup "$INIT"
        printf '%s\n' "$LOAD_LINE" >"$INIT"
        printf 'Replaced the old full copy in %s with: %s\n' "$INIT" "$LOAD_LINE"
    elif [[ ! -e "$INIT" ]] || ! grep -qF "$LOAD_LINE" "$INIT"; then
        if [[ -e "$INIT" ]]; then
            backup "$INIT"
            printf '\n' >>"$INIT"
        fi
        printf '%s\n' "$LOAD_LINE" >>"$INIT"
        printf 'Added to %s: %s\n' "$INIT" "$LOAD_LINE"
    fi

    # 4. Restart Hammerspoon.
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
}

main "$@"

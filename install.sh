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

# --- Logseq CLI helpers (used only while creating the user config) ---

MAX_LISTED=10
PAGE_QUERY='[:find ?t :in $ ?want :where [?p :block/name ?want] [?p :block/title ?t]]'
SIMILAR_QUERY='[:find ?t :in $ ?part :where [?p :block/name ?n] [(clojure.string/includes? ?n ?part)] [?p :block/title ?t]]'
HINT_QUERY='[:find ?t :where [?p :block/name ?n] (or [(clojure.string/includes? ?n "dashboard")] [(clojure.string/includes? ?n "home")] [(clojure.string/includes? ?n "index")] [(clojure.string/includes? ?n "inbox")]) [?p :block/title ?t]]'

find_cli() {
    LOGIN_PATH=$("${SHELL:-/bin/zsh}" -lic 'printf "%s" "$PATH"' </dev/null 2>/dev/null | tail -n 1 || true)
    CLI=$(PATH="${LOGIN_PATH:-$PATH}" command -v logseq || true)
    if [[ "$CLI" != /* ]]; then
        CLI="$HOME/.local/bin/logseq"
    fi
}

cli() {
    PATH="${LOGIN_PATH:-$PATH}" "$CLI" --output json "$@" </dev/null 2>/dev/null || true
}

# Prints one item per line from CLI JSON: "graphs" (graph list) or
# "titles" (first column of a query result). Prints nothing on errors.
json_lines() {
    osascript -l JavaScript -e '
function run(argv) {
    try {
        var d = JSON.parse(argv[0]);
        if (d.status !== "ok") return "";
        var items = argv[1] === "graphs"
            ? d.data.graphs
            : d.data.result.map(function (row) { return row[0]; });
        return items.join("\n");
    } catch (e) { return ""; }
}' "$1" "$2" 2>/dev/null || true
}

query_ok() {
    [[ "$1" == *'"status":"ok"'* ]]
}

lower() {
    perl -CSA -e 'print lc $ARGV[0]' -- "$1"
}

page_titles() {
    json_lines "$(cli --graph "$GRAPH" --timeout-ms 45000 query --query "$1" ${2:+--inputs "$2"})" titles
}

join_lines() {
    awk 'NR > 1 { printf ", " } { printf "%s", $0 }' <<<"$1"
}

print_list() {
    local count
    count=$(grep -c . <<<"$1" || true)
    awk -v max="$MAX_LISTED" 'NR <= max { printf "  %d) %s\n", NR, $0 }' <<<"$1"
    if ((count > MAX_LISTED)); then
        printf '  ... and %d more (type a name)\n' $((count - MAX_LISTED))
    fi
}

# Sets GRAPH. Only names from `graph list` are accepted: querying an unknown
# graph makes the CLI create an empty one.
choose_graph() {
    local graphs answer similar
    graphs=$(json_lines "$(cli graph list)" graphs)

    if [[ -z "$graphs" ]]; then
        printf 'Could not list graphs with %s; the name is not checked.\n' "$CLI"
        GRAPH=${LOGSEQ_GRAPH:-$(ask 'Logseq graph name (e.g. Personal): ')}
        [[ -n "$GRAPH" ]] || fail_no_answer LOGSEQ_GRAPH '<graph>'
        GRAPH_CHECKED=""
        return
    fi

    printf 'Local Logseq graphs:\n'
    print_list "$graphs"

    while true; do
        answer=${LOGSEQ_GRAPH:-$(ask 'Graph (number or name, e.g. 1): ')}
        [[ -n "$answer" ]] || fail_no_answer LOGSEQ_GRAPH '<graph>'

        if [[ "$answer" =~ ^[0-9]+$ ]] && ((10#$answer >= 1 && 10#$answer <= MAX_LISTED)); then
            answer=$(sed -n "$((10#$answer))p" <<<"$graphs")
        fi

        if [[ -n "$answer" ]] && grep -qxF -- "$answer" <<<"$graphs"; then
            GRAPH=$answer
            GRAPH_CHECKED=1
            return
        fi

        printf 'No graph "%s".\n' "$answer"
        similar=$(grep -iF -- "$answer" <<<"$graphs" | head -n 5 || true)
        [[ -z "$similar" ]] || printf 'Similar: %s\n' "$(join_lines "$similar")"
        [[ -z "${LOGSEQ_GRAPH:-}" ]] || exit 1
    done
}

# Sets DASHBOARD (may be empty). Checks the page exists when the graph is known.
choose_dashboard() {
    local answer hints found similar result

    if [[ -n "$GRAPH_CHECKED" ]]; then
        hints=$(page_titles "$HINT_QUERY" | head -n 5 || true)
        [[ -z "$hints" ]] || printf 'Pages that may fit: %s\n' "$(join_lines "$hints")"
    fi

    while true; do
        if [[ -n "${LOGSEQ_DASHBOARD+set}" ]]; then
            answer=$LOGSEQ_DASHBOARD
        else
            answer=$(ask 'Page for the panel'\''s top-right button (e.g. Dashboard; empty = no button): ')
        fi

        if [[ -z "$answer" || -z "$GRAPH_CHECKED" ]]; then
            DASHBOARD=$answer
            return
        fi

        result=$(cli --graph "$GRAPH" --timeout-ms 45000 query --query "$PAGE_QUERY" \
            --inputs "[$(lua_string "$(lower "$answer")")]")
        if ! query_ok "$result"; then
            printf 'Could not check pages; saving "%s" unchecked.\n' "$answer"
            DASHBOARD=$answer
            return
        fi

        found=$(json_lines "$result" titles | head -n 1 || true)
        if [[ -n "$found" ]]; then
            DASHBOARD=$found
            return
        fi

        printf 'No page "%s" in graph "%s".\n' "$answer" "$GRAPH"
        similar=$(page_titles "$SIMILAR_QUERY" "[$(lua_string "$(lower "$answer")")]" | head -n 5 || true)
        [[ -z "$similar" ]] || printf 'Similar: %s\n' "$(join_lines "$similar")"
        [[ -z "${LOGSEQ_DASHBOARD+set}" ]] || exit 1
    done
}

fail_no_answer() {
    printf 'No answer. Re-run with %s="%s".\n' "$1" "$2" >&2
    exit 1
}

# Wrapped in main so a partial download (curl | bash) never runs.
main() {
    mkdir -p "$CONFIG_DIR"

    # 1. User config: created once, kept on updates.
    if [[ ! -e "$USER_CONFIG" ]]; then
        find_cli
        if [[ ! -x "$CLI" ]]; then
            printf 'Logseq CLI not found; using %s (edit %s if wrong).\n' "$CLI" "$USER_CONFIG"
        fi
        choose_graph
        choose_dashboard

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

#!/bin/bash
# Install or update logseq-hammerspoon.
#
#   curl -fsSL https://raw.githubusercontent.com/offcall/logseq-hammerspoon/main/install.sh | bash
#
# or ./install.sh from a clone. Optional: LOGSEQ_GRAPH and LOGSEQ_DASHBOARD
# answer the first-run questions without a prompt.
set -euo pipefail

TARBALL_URL="https://codeload.github.com/offcall/logseq-hammerspoon/tar.gz/main"
TARBALL_ROOT="logseq-hammerspoon-main"
CONFIG_DIR="$HOME/.hammerspoon"
MODULE_DIR="$CONFIG_DIR/logseq_capture"
# Single-file script of older versions; require() would pick it over the directory.
OLD_SCRIPT="$CONFIG_DIR/logseq_capture.lua"
USER_CONFIG="$CONFIG_DIR/logseq_capture_config.lua"
INIT="$CONFIG_DIR/init.lua"
LOAD_LINE='require("logseq_capture")'
# Header line of the script; marks an init.lua that is a full copy of it.
OLD_COPY_MARKER='Logseq Capture + Today panel for Hammerspoon'

# --- Output ---

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m'
    YELLOW=$'\e[33m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
fi

STEP=0
STEPS=1

section() {
    STEP=$((STEP + 1))
    printf '\n%s[%d/%d] %s%s\n' "$BOLD" "$STEP" "$STEPS" "$1" "$RESET"
}
ok()   { printf '  %s[ok]%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s[!!]%s %s\n' "$YELLOW" "$RESET" "$1"; }
bad()  { printf '  %s[no]%s %s\n' "$RED" "$RESET" "$1"; }
note() { printf '       %s%s%s\n' "$DIM" "$1" "$RESET"; }
em()   { printf '%s%s%s' "$BOLD" "$1" "$RESET"; }

# Install step result: label column, then details.
step() { ok "$(printf '%-12s %s%s%s' "$1" "$DIM" "$2" "$RESET")"; }

tilde() {
    if [[ "$1" == "$HOME"/* ]]; then
        printf '~%s' "${1#"$HOME"}"
    else
        printf '%s' "$1"
    fi
}

backup() {
    local backup
    backup=$(mktemp "$1.backup.XXXXXX")
    cp -p "$1" "$backup"
    step "Backup" "$(tilde "$backup")"
}

ask() {
    local answer=""
    # The prompt goes to the terminal: stdout is captured, stdin may be curl.
    if { : </dev/tty; } 2>/dev/null; then
        read -r -p "     ${CYAN}>${RESET} $1 " answer </dev/tty 2>/dev/tty || true
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
    awk -v max="$MAX_LISTED" -v c="$CYAN" -v r="$RESET" \
        'NR <= max { printf "      %s%2d)%s %s\n", c, NR, r, $0 }' <<<"$1"
    if ((count > MAX_LISTED)); then
        note "... and $((count - MAX_LISTED)) more, type a name"
    fi
}

listed_count() {
    local count
    count=$(grep -c . <<<"$1" || true)
    printf '%d' $((count < MAX_LISTED ? count : MAX_LISTED))
}

# Echoes line N of a list when the answer is a listed number, else the answer.
pick() {
    if [[ -n "$2" && "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= $(listed_count "$2"))); then
        sed -n "$((10#$1))p" <<<"$2"
    else
        printf '%s' "$1"
    fi
}

# Sets GRAPH. Only names from `graph list` are accepted: querying an unknown
# graph makes the CLI create an empty one.
choose_graph() {
    local graphs answer similar
    graphs=$(json_lines "$(cli graph list)" graphs)

    section "Graph"

    if [[ -z "$graphs" ]]; then
        warn "Could not list graphs with $(tilde "$CLI"); the name is not checked."
        GRAPH=${LOGSEQ_GRAPH:-$(ask 'Graph name (e.g. Personal):')}
        [[ -n "$GRAPH" ]] || fail_no_answer LOGSEQ_GRAPH '<graph>'
        GRAPH_CHECKED=""
        return
    fi

    print_list "$graphs"

    while true; do
        answer=${LOGSEQ_GRAPH:-$(ask "Choose [1-$(listed_count "$graphs") or name]:")}
        [[ -n "$answer" ]] || fail_no_answer LOGSEQ_GRAPH '<graph>'
        answer=$(pick "$answer" "$graphs")

        if grep -qxF -- "$answer" <<<"$graphs"; then
            GRAPH=$answer
            GRAPH_CHECKED=1
            ok "Graph $(em "$GRAPH")"
            return
        fi

        bad "No graph $(em "$answer")"
        similar=$(grep -iF -- "$answer" <<<"$graphs" | head -n 5 || true)
        [[ -z "$similar" ]] || note "Did you mean: $(join_lines "$similar")"
        [[ -z "${LOGSEQ_GRAPH:-}" ]] || exit 1
    done
}

# Sets DASHBOARD (may be empty). Checks the page exists when the graph is known.
choose_dashboard() {
    local answer hints found similar result

    section "Dashboard button"
    note "The page that the panel's top-right button opens."

    hints=""
    if [[ -n "$GRAPH_CHECKED" ]]; then
        hints=$(page_titles "$HINT_QUERY" | head -n 5 || true)
        [[ -z "$hints" ]] || print_list "$hints"
    fi

    while true; do
        if [[ -n "${LOGSEQ_DASHBOARD+set}" ]]; then
            answer=$LOGSEQ_DASHBOARD
        else
            if [[ -n "$hints" ]]; then
                answer=$(ask "Choose [1-$(listed_count "$hints"), page name, or empty for no button]:")
            else
                answer=$(ask 'Page name (e.g. Dashboard; empty for no button):')
            fi
        fi
        answer=$(pick "$answer" "$hints")

        if [[ -z "$answer" ]]; then
            DASHBOARD=""
            ok "No dashboard button"
            return
        fi

        if [[ -z "$GRAPH_CHECKED" ]]; then
            DASHBOARD=$answer
            ok "Button opens $(em "$DASHBOARD") (not checked)"
            return
        fi

        result=$(cli --graph "$GRAPH" --timeout-ms 45000 query --query "$PAGE_QUERY" \
            --inputs "[$(lua_string "$(lower "$answer")")]")
        if ! query_ok "$result"; then
            DASHBOARD=$answer
            warn "Could not check pages; saved \"$DASHBOARD\" unchecked"
            return
        fi

        found=$(json_lines "$result" titles | head -n 1 || true)
        if [[ -n "$found" ]]; then
            DASHBOARD=$found
            ok "Button opens $(em "$DASHBOARD")"
            return
        fi

        bad "No page $(em "$answer") in graph $(em "$GRAPH")"
        similar=$(page_titles "$SIMILAR_QUERY" "[$(lua_string "$(lower "$answer")")]" | head -n 5 || true)
        [[ -z "$similar" ]] || note "Did you mean: $(join_lines "$similar")"
        [[ -z "${LOGSEQ_DASHBOARD+set}" ]] || exit 1
    done
}

fail_no_answer() {
    bad "No answer. Re-run with $1=\"$2\"" >&2
    exit 1
}

# Wrapped in main so a partial download (curl | bash) never runs.
main() {
    mkdir -p "$CONFIG_DIR"
    printf '%slogseq-hammerspoon installer%s\n' "$BOLD" "$RESET"
    printf '%s============================%s\n' "$DIM" "$RESET"
    [[ -e "$USER_CONFIG" ]] || STEPS=3
    CONFIG_STATUS="kept $(tilde "$USER_CONFIG")"

    # 1. User config: created once, kept on updates.
    if [[ ! -e "$USER_CONFIG" ]]; then
        find_cli
        if [[ ! -x "$CLI" ]]; then
            warn "Not found; using $(tilde "$CLI"), edit $(tilde "$USER_CONFIG") if wrong."
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
        CONFIG_STATUS="created $(tilde "$USER_CONFIG")"
    fi

    section "Install"
    step "Config" "$CONFIG_STATUS"

    # 2. Script directory: copy from a clone, otherwise download the tarball.
    #    Staged next to the target, then swapped in.
    SOURCE_DIR=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    fi

    STAGE=$(mktemp -d "$CONFIG_DIR/.logseq_capture.XXXXXX")
    trap 'rm -rf "$STAGE"' EXIT
    if [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/logseq_capture/init.lua" ]]; then
        cp -R "$SOURCE_DIR/logseq_capture" "$STAGE/"
    else
        curl -fsSL "$TARBALL_URL" |
            tar -xzf - -C "$STAGE" --strip-components=1 "$TARBALL_ROOT/logseq_capture"
    fi
    if [[ ! -f "$STAGE/logseq_capture/init.lua" ]]; then
        bad "Download has no logseq_capture/init.lua; nothing changed."
        exit 1
    fi
    rm -rf "$MODULE_DIR"
    mv "$STAGE/logseq_capture" "$MODULE_DIR"
    step "Script" "$(tilde "$MODULE_DIR")/"
    if [[ -e "$OLD_SCRIPT" ]]; then
        rm -f "$OLD_SCRIPT"
        step "Old script" "removed $(tilde "$OLD_SCRIPT")"
    fi

    # 3. init.lua loads the script.
    if [[ -e "$INIT" ]] && grep -qF "$OLD_COPY_MARKER" "$INIT"; then
        backup "$INIT"
        printf '%s\n' "$LOAD_LINE" >"$INIT"
        step "init.lua" "old full copy replaced with $LOAD_LINE"
    elif [[ ! -e "$INIT" ]] || ! grep -qF "$LOAD_LINE" "$INIT"; then
        if [[ -e "$INIT" ]]; then
            backup "$INIT"
            printf '\n' >>"$INIT"
        fi
        printf '%s\n' "$LOAD_LINE" >>"$INIT"
        step "init.lua" "added $LOAD_LINE"
    else
        step "init.lua" "already loads the script"
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
    step "Hammerspoon" "restarted"

    printf '\n%sDone.%s Push the mouse into the bottom-right corner of the screen.\n' "$BOLD" "$RESET"
}

main "$@"

-- ============================================================
-- Logseq Capture + Today panel for Hammerspoon
--
-- CAPTURE (textarea)
--   Enter        → Note      (today's Journal)
--   Shift+Enter  → newline
--   Cmd+T        → Task for Today      (deadline = today)
--   Cmd+Shift+T  → Task for Tomorrow   (deadline = tomorrow)
--   Cmd+D        → Task for a date     (picker: 1–6 quick, arrows, ↩ create)
--   Cmd+B        → Backlog task
--   Cmd+P        → Page (create + open in Logseq)
--   ↓ / Tab      → jump into the task list
--
-- TASK LIST (Expired · In progress · Today · Tomorrow · Done today)
--   ↑↓ / j k     → move selection        Space / x → done
--   s            → start / pause          t        → tomorrow (← today)
--   d            → reschedule menu (1–5 pick, 6 = date)
--   b            → backlog (clears dates) ↩ / o    → open in Logseq
--   double-click a row (not its buttons) → open that block in Logseq
--   ⌘Z           → undo last action       ⌘R       → refresh
--   ⌘F           → search tasks (Esc clears, ↓ / ↩ jump into the list)
--   c            → toggle List / Calendar (2-week grid, ←→ day, ⇧←→ week)
--   / or n       → back to the input      Esc      → close menu / panel
--
-- SETTINGS (⌘, or the gear in the header): which tasks the panel shows
--   statuses or a custom datalog query
--   ⌘↩           → test                   ⌘S       → save (after a passing test)
--   Esc          → back to the task list
--
-- PEEK: a small pill bottom-right with your current "Doing" tasks, one row
-- each, with elapsed time since the task was last started through this panel.
-- slides right on hover to reveal the screen underneath.
--
-- Talks to Logseq only through the official CLI (`logseq … --output json`),
-- asynchronously via hs.task, one command at a time.
-- ============================================================

-- Modules (logseq_capture/*.lua, web UI in logseq_capture/web/):
--   config   user config + constants      state    _G.logseqCapture + reload cleanup
--   util     helpers                      bridge   Lua → JS calls
--   cli      Logseq CLI runner            queue    sequential CLI queue + refresh
--   done     "Done today" list            tasks    rows of the last refresh
--   filter   tasks query + saved filter   settings settings screen messages
--   actions  task updates / captures      peek     Doing pill
--   panel    capture + task list          corner   hot corner
--   assets   web/ files → one HTML string

local S = require("logseq_capture.state")   -- first: cleans up the old instance
local config = require("logseq_capture.config")
local util = require("logseq_capture.util")
local cli = require("logseq_capture.cli")
local done = require("logseq_capture.done")
local queue = require("logseq_capture.queue")
local peek = require("logseq_capture.peek")
local panel = require("logseq_capture.panel")
local corner = require("logseq_capture.corner")

local log = util.log


-- ============================================================
-- START
-- ============================================================

done.roll()

S.env = cli.captureUserEnv()

if not S.env then
    log("could not capture user env — falling back to " .. config.USER_SHELL .. " -l -i -c")
end

queue.onData = panel.applyData

panel.create()
peek.create(panel.show)

if config.OPEN_HOTKEY then
    S.hotkey = hs.hotkey.bind(config.OPEN_HOTKEY[1], config.OPEN_HOTKEY[2], panel.toggle)
end

-- Background refresh keeps the peek honest (and catches day change).
S.refreshTimer = hs.timer.doEvery(config.REFRESH_INTERVAL, function()
    if config.SHOW_PEEK or S.visible then
        queue.requestRefresh()
    end
end)

queue.requestRefresh()

corner.start()


log("loaded — panel + peek, async CLI (" .. (S.env and "direct" or "shell") .. ")")

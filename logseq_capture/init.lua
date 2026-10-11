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
-- PEEK: a small pill bottom-right with your current "Doing" tasks, one row
-- each, with elapsed time since the task was last started through this panel.
-- slides right on hover to reveal the screen underneath.
--
-- Talks to Logseq only through the official CLI (`logseq … --output json`),
-- asynchronously via hs.task, one command at a time.
-- ============================================================

-- ============================================================
-- USER CONFIG
-- Optional ~/.hammerspoon/logseq_capture_config.lua returning a table,
-- e.g. return { graph = "Work", dashboardPage = false }
-- Keys: logseq (CLI path), graph, dashboardPage (false hides the
-- button), openHotkey. Missing keys use the defaults below.
-- ============================================================

local CONFIG_FILE = hs.configdir .. "/logseq_capture_config.lua"

local function loadUserConfig()
    if not hs.fs.attributes(CONFIG_FILE) then
        return {}
    end

    local ok, config = pcall(dofile, CONFIG_FILE)

    if not ok or type(config) ~= "table" then
        print("[Logseq Panel] bad config " .. CONFIG_FILE .. ": " .. tostring(config))
        hs.alert.show("❌ Logseq: bad config file, using defaults", 3)
        return {}
    end

    return config
end

local USER_CONFIG = loadUserConfig()

local function setting(key, default)
    local value = USER_CONFIG[key]

    if value == nil then
        return default
    end

    return value
end

local LOGSEQ = setting("logseq", os.getenv("HOME") .. "/.local/bin/logseq")
local GRAPH = setting("graph", "Personal")
local DASHBOARD_PAGE = setting("dashboardPage", "Dashboard")

local WIDTH = 460
local MIN_HEIGHT = 150
local MAX_HEIGHT = 720
local SCREEN_MARGIN = 18

local CORNER_SIZE = 14
local REARM_DISTANCE = 80

local CLI_TIMEOUT = 45           -- seconds; first call may start db-worker
local REFRESH_INTERVAL = 300     -- seconds; background refresh (for the peek)

local SHOW_PEEK = true
local PEEK_WIDTH = 380
local PEEK_ROW_HEIGHT = 28       -- one Doing task in the peek
local PEEK_MAX_ROWS = 5

-- Optional global hotkey to toggle the panel, e.g. { {"cmd", "alt"}, "L" }
local OPEN_HOTKEY = setting("openHotkey", nil)

-- Status values as the CLI accepts them (it normalizes case / prefixes).
local STATUS = {
    todo = "todo",
    doing = "doing",
    done = "done",
    backlog = "backlog",
}

local VALID_STATUS = {
    todo = true, doing = true, done = true,
    backlog = true, ["in-review"] = true, canceled = true,
}

-- Every dated task before ?until + every Doing task, in ONE query.
-- ?until = end of the calendar grid: Monday of the week after next
-- (local time, epoch ms). The list mode filters to tomorrow in JS.
local TASKS_QUERY = [=[
[:find (pull ?task [:db/id
                    :block/uuid
                    :block/title
                    :block/updated-at
                    :logseq.property/deadline
                    :logseq.property/scheduled
                    {:logseq.property/status [:db/ident]}
                    {:logseq.property/priority [:db/ident]}
                    {:block/refs [:block/uuid :block/title]}])
 :in $ ?until
 :where
 (or-join [?task]
   (and
     [?task :logseq.property/status ?status]
     [?status :db/ident ?status-id]
     [(contains?
       #{:logseq.property/status.todo
         :logseq.property/status.backlog
         :logseq.property/status.doing
         :logseq.property/status.in-review}
       ?status-id)])
   ;; a #Task without a status counts as todo
   (and
     [?task-class :db/ident :logseq.class/Task]
     [?task :block/tags ?task-class]
     (not [?task :logseq.property/status])))
 (or-join [?task ?until]
   (and
     [?task :logseq.property/status ?doing]
     [?doing :db/ident :logseq.property/status.doing])
   (and
     [?task :logseq.property/deadline ?date]
     [(< ?date ?until)])
   (and
     [?task :logseq.property/scheduled ?date]
     [(< ?date ?until)]))]
]=]


-- ============================================================
-- CLEAN UP OLD INSTANCE AFTER RELOAD
-- (also handles the previous version of this file)
-- ============================================================

if _G.logseqCapture then
    local old = _G.logseqCapture

    for _, key in ipairs({ "cornerTimer", "refreshTimer" }) do
        if old[key] then
            pcall(function() old[key]:stop() end)
        end
    end

    if old.hotkey then
        pcall(function() old.hotkey:delete() end)
    end

    if old.currentTask then
        pcall(function()
            if old.currentTask:isRunning() then
                old.currentTask:terminate()
            end
        end)
    end

    for _, key in ipairs({ "popup", "peek" }) do
        if old[key] then
            pcall(function() old[key]:hide() end)
            pcall(function() old[key]:delete() end)
        end
    end
end


_G.logseqCapture = {
    popup = nil,
    usercontent = nil,
    peek = nil,
    peekContent = nil,

    cornerTimer = nil,
    refreshTimer = nil,
    hotkey = nil,

    ready = false,
    peekReady = false,
    pendingShow = false,
    visible = false,
    peekVisible = false,
    peekHovered = false,
    lastHeight = MIN_HEIGHT,

    cornerArmed = true,
    canBlurClose = false,
    blurPinned = false,

    env = nil,
    queue = {},
    busy = false,
    refreshWanted = false,
    currentTask = nil,

    cache = nil,
    done = nil,
}

local S = _G.logseqCapture
local TASK_STARTS_KEY = "logseqCapture.taskStarts." .. GRAPH
S.taskStarts = hs.settings.get(TASK_STARTS_KEY)
if type(S.taskStarts) ~= "table" then S.taskStarts = {} end

local USER_SHELL = os.getenv("SHELL") or "/bin/zsh"


-- ============================================================
-- HELPERS
-- ============================================================

local function log(...)
    print("[Logseq Panel]", ...)
end


local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end


local function containsPoint(frame, point)
    return point.x >= frame.x and point.x < frame.x + frame.w
        and point.y >= frame.y and point.y < frame.y + frame.h
end


local function shellQuote(value)
    return "'" .. (tostring(value):gsub("'", "'\"'\"'")) .. "'"
end


local function urlEncode(value)
    return (
        tostring(value):gsub(
            "([^%w%-_%.~])",
            function(c)
                return string.format("%%%02X", string.byte(c))
            end
        )
    )
end


local function fmtInt(value)
    return string.format("%.0f", tonumber(value) or 0)
end


-- Local midnight of today + offset days, epoch ms.
local function dayStartMs(offsetDays)
    local t = os.date("*t")

    return os.time({
        year = t.year,
        month = t.month,
        day = t.day + (offsetDays or 0),
        hour = 0, min = 0, sec = 0,
    }) * 1000
end


local function jsPanel(code)
    if S.popup and S.ready then
        S.popup:evaluateJavaScript(
            "try{" .. code .. "}catch(e){console.error(e)}"
        )
    end
end


local function jsPeek(code)
    if S.peek and S.peekReady then
        S.peek:evaluateJavaScript(
            "try{" .. code .. "}catch(e){console.error(e)}"
        )
    end
end


local function notifyError(req, message)
    message = tostring(message or "unknown error")

    if S.visible then
        jsPanel(
            "app.result(" ..
            hs.json.encode({ req = req or 0, ok = false, message = message }) ..
            ")"
        )
    else
        hs.alert.show("❌ Logseq: " .. message, 3)
    end
end


-- ============================================================
-- USER ENVIRONMENT
-- The CLI is a node script: it needs the PATH from your login shell.
-- Captured once (same path hs.execute(..., true) used before);
-- every CLI call then runs directly via hs.task, without a shell.
-- ============================================================

local function captureUserEnv()
    local output, ok = hs.execute("/usr/bin/env", true)

    if not ok or not output then
        return nil
    end

    local env = {}

    for line in output:gmatch("[^\n]+") do
        local key, value = line:match("^([%a_][%w_]*)=(.*)$")

        if key then
            env[key] = value
        end
    end

    if not env.PATH or env.PATH == "" then
        return nil
    end

    env.NO_COLOR = "1"
    env.FORCE_COLOR = "0"

    return env
end


-- ============================================================
-- CLI RUNNER (async, single command)
-- ============================================================

local function extractJson(output)
    if not output or output == "" then
        return nil
    end

    local i =
        output:find('{"status"', 1, true)
        or output:find("{", 1, true)

    if not i then
        return nil
    end

    local j = output:match("^.*()}")

    if not j or j < i then
        return nil
    end

    return output:sub(i, j)
end


local function startCli(args, callback)
    local full = { "--graph", GRAPH, "--output", "json" }

    for _, arg in ipairs(args) do
        full[#full + 1] = tostring(arg)
    end

    local preview = {}
    for i, arg in ipairs(full) do
        local flat = arg:gsub("%s+", " ")
        preview[i] = #flat > 80 and (flat:sub(1, 77) .. "...") or flat
    end
    log("RUN:", LOGSEQ .. " " .. table.concat(preview, " "))

    local finished = false
    local task
    local watchdog

    local function finish(code, stdout, stderr)
        if finished then
            return
        end

        finished = true
        stdout = stdout or ""
        stderr = stderr or ""

        if watchdog then
            watchdog:stop()
        end

        if S.currentTask == task then
            S.currentTask = nil
        end

        local raw = extractJson(stdout)
        local decoded

        if raw then
            local okDecode, value = pcall(hs.json.decode, raw)

            if okDecode and type(value) == "table" then
                decoded = value
            else
                raw = nil
            end
        end

        local ok =
            code == 0 and
            decoded ~= nil and
            decoded.status == "ok"

        local message

        if not ok then
            if decoded and type(decoded.error) == "table" then
                message = decoded.error.message or decoded.error.code
            end

            if not message or message == "" then
                message = (stderr ~= "" and stderr) or (stdout ~= "" and stdout) or ("exit code " .. tostring(code))
            end

            message = tostring(message):gsub("%s+", " "):sub(1, 220)

            log("FAILED (" .. tostring(code) .. ")")
            if stdout ~= "" then print(stdout) end
            if stderr ~= "" then print(stderr) end
        end

        local okCb, err = pcall(callback, ok, raw, decoded, message)

        if not okCb then
            log("callback error:", err)
        end
    end

    if S.env then
        task = hs.task.new(LOGSEQ, finish, full)

        if task then
            task:setEnvironment(S.env)
        end
    else
        -- Fallback: same login+interactive shell hs.execute(cmd, true) uses.
        local parts = { shellQuote(LOGSEQ) }

        for _, arg in ipairs(full) do
            parts[#parts + 1] = shellQuote(arg)
        end

        task = hs.task.new(
            USER_SHELL,
            finish,
            { "-l", "-i", "-c", table.concat(parts, " ") }
        )
    end

    if not task then
        finish(-1, "", "could not create hs.task")
        return
    end

    S.currentTask = task

    if not task:start() then
        finish(-1, "", "could not start " .. LOGSEQ)
        return
    end

    watchdog = hs.timer.doAfter(CLI_TIMEOUT, function()
        if finished then
            return
        end

        log("TIMEOUT after " .. CLI_TIMEOUT .. "s")

        pcall(function()
            if task:isRunning() then
                task:terminate()
            end
        end)

        hs.timer.doAfter(2, function()
            finish(-1, "", "timed out after " .. CLI_TIMEOUT .. "s")
        end)
    end)
end


-- ============================================================
-- DONE-TODAY LIST (done tasks leave the queries, keep them visible)
-- ============================================================

local DONE_KEY = "logseqCapture.doneToday"


local function todayKey()
    return os.date("%Y-%m-%d")
end


local function saveDone()
    hs.settings.set(DONE_KEY, S.done)
end


local function rollDone()
    if type(S.done) ~= "table" then
        local stored = hs.settings.get(DONE_KEY)

        if type(stored) == "table" and type(stored.items) == "table" then
            S.done = stored
        end
    end

    if type(S.done) ~= "table"
        or S.done.date ~= todayKey()
        or type(S.done.items) ~= "table"
    then
        S.done = { date = todayKey(), items = {} }
        saveDone()
    end
end


local function unmarkDone(id)
    rollDone()

    local key = fmtInt(id)
    local items = {}

    for _, item in ipairs(S.done.items) do
        if fmtInt(item.id) ~= key then
            items[#items + 1] = item
        end
    end

    S.done.items = items
    saveDone()
end


local function markDone(id, uuid, title)
    unmarkDone(id)

    table.insert(S.done.items, 1, {
        id = tonumber(id),
        uuid = tostring(uuid or ""),
        title = tostring(title or ""),
        modifiedAt = hs.timer.secondsSinceEpoch() * 1000,
    })

    while #S.done.items > 50 do
        table.remove(S.done.items)
    end

    saveDone()
end


-- ============================================================
-- QUEUE: writes and refreshes run strictly one after another.
-- A refresh result is applied only if no write is waiting,
-- so optimistic UI never gets overwritten by stale data.
-- ============================================================

local pump
local applyData
local updatePeek


local function enqueue(job)
    S.queue[#S.queue + 1] = job
    pump()
end


local function requestRefresh()
    S.refreshWanted = true
    pump()
end


local function makeRefreshJob()
    local start = dayStartMs(0)
    local finish = dayStartMs(1)
    local finish2 = dayStartMs(2)
    -- Monday of this week + 14 days (os.date wday: 1 = Sunday).
    local untilMs = dayStartMs(14 - (os.date("*t").wday + 5) % 7)

    return {
        kind = "refresh",
        args = {
            "query",
            "--query", TASKS_QUERY,
            "--inputs", "[" .. fmtInt(untilMs) .. "]",
        },
        cb = function(ok, raw, decoded, message)
            jsPanel("app.setLoading(false)")

            if #S.queue > 0 then
                -- writes arrived meanwhile → this snapshot is stale
                S.refreshWanted = true
                return
            end

            if not ok then
                jsPanel("app.setError(" .. hs.json.encode({ message = message or "query failed" }) .. ")")
                return
            end

            S.cache = {
                raw = raw,
                decoded = decoded,
                start = start,
                ["end"] = finish,
                end2 = finish2,
                ["until"] = untilMs,
            }

            applyData()
        end,
    }
end


pump = function()
    if S.busy then
        return
    end

    local job = table.remove(S.queue, 1)

    if not job then
        if not S.refreshWanted then
            return
        end

        S.refreshWanted = false
        job = makeRefreshJob()
        jsPanel("app.setLoading(true)")
    end

    S.busy = true

    startCli(job.args, function(...)
        S.busy = false

        local okCb, err = pcall(job.cb, ...)

        if not okCb then
            log("job callback error:", err)
        end

        -- let the UI breathe between commands
        hs.timer.doAfter(0, pump)
    end)
end


local function enqueueWrite(args, onDone)
    enqueue({
        kind = "write",
        args = args,
        cb = function(ok, raw, decoded, message)
            S.refreshWanted = true

            if onDone then
                onDone(ok, message, decoded)
            end
        end,
    })
end


-- ============================================================
-- DATA → WEBVIEWS
-- ============================================================

local function pulls()
    local list = {}

    if not (S.cache and S.cache.decoded and type(S.cache.decoded.data) == "table") then
        return list
    end

    local result = S.cache.decoded.data.result

    if type(result) ~= "table" then
        return list
    end

    for _, row in ipairs(result) do
        local pull = row

        if type(row) == "table" and row[1] ~= nil then
            pull = row[1]
        end

        if type(pull) == "table" then
            list[#list + 1] = pull
        end
    end

    return list
end


local function identOf(value)
    if type(value) == "table" then
        value = value["db/ident"]
    end

    if type(value) ~= "string" then
        return ""
    end

    return value:gsub("^:", ""):match("([^%.]+)$") or ""
end


applyData = function()
    if not S.cache then
        return
    end

    rollDone()

    local active = {}
    for _, pull in ipairs(pulls()) do
        if identOf(pull["logseq.property/status"]) == "doing" then
            active[fmtInt(pull["db/id"])] = true
        end
    end
    local changed = false
    for id in pairs(S.taskStarts) do
        if not active[id] then
            S.taskStarts[id] = nil
            changed = true
        end
    end
    if changed then hs.settings.set(TASK_STARTS_KEY, S.taskStarts) end

    local meta = hs.json.encode({
        start = S.cache.start,
        ["end"] = S.cache["end"],
        end2 = S.cache.end2,
        ["until"] = S.cache["until"],
        done = S.done.items,
    })

    jsPanel("app.setData(" .. S.cache.raw .. "," .. meta .. ")")

    updatePeek()
end


local function peekHeight(rows)
    -- 8px transparent padding on each side + 4px pill padding on each side.
    return math.min(rows, PEEK_MAX_ROWS) * PEEK_ROW_HEIGHT + 24
end


local function positionPeek(rows)
    if not S.peek then
        return
    end

    local screen = hs.screen.mainScreen()

    if not screen then
        return
    end

    local frame = screen:frame()
    local height = peekHeight(rows)

    S.peek:frame({
        x = frame.x + frame.w - PEEK_WIDTH - SCREEN_MARGIN + 8,
        y = frame.y + frame.h - height - SCREEN_MARGIN + 8,
        w = PEEK_WIDTH,
        h = height,
    })
end


local function hidePeek()
    if S.peekHovered then
        S.peekHovered = false
        jsPeek("peek.setHovered(false)")
    end

    if S.peek and S.peekVisible then
        S.peek:hide()
        S.peekVisible = false
    end
end


local function updatePeekHover(position)
    if not S.peek or not (S.peekVisible or S.peekHovered) then
        return
    end

    -- Keep using the original frame even while the webview is hidden.
    local hovered = containsPoint(S.peek:frame(), position)

    if hovered ~= S.peekHovered then
        S.peekHovered = hovered
        jsPeek("peek.setHovered(" .. tostring(hovered) .. ")")

        if not hovered then
            updatePeek()
        end
    end
end


updatePeek = function()
    if not SHOW_PEEK or not S.peek or not S.peekReady then
        return
    end

    if S.visible or not S.cache then
        hidePeek()
        return
    end

    local tasks = {}

    for _, pull in ipairs(pulls()) do
        if identOf(pull["logseq.property/status"]) == "doing" then
            local refs = {}

            if type(pull["block/refs"]) == "table" then
                for _, ref in ipairs(pull["block/refs"]) do
                    if type(ref) == "table" and ref["block/uuid"] and ref["block/title"] then
                        refs[#refs + 1] = {
                            uuid = tostring(ref["block/uuid"]),
                            title = tostring(ref["block/title"]),
                        }
                    end
                end
            end

            tasks[#tasks + 1] = {
                id = pull["db/id"],
                title = tostring(pull["block/title"] or ""),
                refs = refs,
                startedAt = S.taskStarts[fmtInt(pull["db/id"])],
            }
        end
    end

    if #tasks == 0 then
        hidePeek()
        return
    end

    jsPeek("peek.set(" .. hs.json.encode(tasks) .. ")")

    positionPeek(#tasks)

    if S.peekHovered then
        return
    end

    if not S.peekVisible then
        S.peek:show()
        S.peekVisible = true
    end
end


-- ============================================================
-- ACTIONS FROM THE UI
-- ============================================================

local function openLogseqUrl(query)
    local url = "logseq://graph/" .. urlEncode(GRAPH) .. "?" .. query
    log("OPEN:", url)
    hs.urlevent.openURL(url)
end


local function handleUpdate(body)
    local args = { "upsert", "task" }

    if type(body.uuid) == "string" and body.uuid:match("^%x+%-[%x%-]+$") then
        args[#args + 1] = "--uuid"
        args[#args + 1] = body.uuid
    elseif tonumber(body.id) then
        args[#args + 1] = "--id"
        args[#args + 1] = fmtInt(body.id)
    else
        log("update without id/uuid ignored")
        return
    end

    local changed = false
    local status = type(body.status) == "string" and body.status or ""

    if status ~= "" then
        if not VALID_STATUS[status] then
            log("unknown status ignored:", status)
            return
        end

        args[#args + 1] = "--status"
        args[#args + 1] = STATUS[status] or status
        changed = true
    end

    for _, field in ipairs({ "deadline", "scheduled" }) do
        local mode = body[field .. "Mode"]

        if mode == "set" and tonumber(body[field]) then
            args[#args + 1] = "--" .. field
            args[#args + 1] = fmtInt(body[field])
            changed = true
        elseif mode == "clear" then
            args[#args + 1] = "--no-" .. field
            changed = true
        end
    end

    if not changed then
        return
    end

    local startedAt = hs.timer.secondsSinceEpoch() * 1000
    enqueueWrite(args, function(ok, message)
        if ok then
            if status ~= "" and body.id then
                S.taskStarts[fmtInt(body.id)] = status == "doing" and startedAt or nil
                hs.settings.set(TASK_STARTS_KEY, S.taskStarts)
            end
            if status == "done" then
                markDone(body.id, body.uuid, body.title)
            elseif status ~= "" then
                unmarkDone(body.id)
            end
        else
            notifyError(body.req, message)
        end
    end)
end


local function handleCapture(body)
    local text = trim(body.text)

    if text == "" then
        return
    end

    local kind = body.kind

    if kind == "note" then
        enqueueWrite(
            { "upsert", "block", "--content", text },
            function(ok, message)
                if not ok then notifyError(body.req, message) end
            end
        )

    elseif kind == "backlog" then
        enqueueWrite(
            { "upsert", "task", "--content", text, "--status", STATUS.backlog },
            function(ok, message)
                if not ok then notifyError(body.req, message) end
            end
        )

    elseif kind == "today" or kind == "tomorrow" or kind == "date" then
        local ms = tonumber(body.ms) or dayStartMs(kind == "today" and 0 or 1)

        enqueueWrite(
            {
                "upsert", "task",
                "--content", text,
                "--status", STATUS.todo,
                "--deadline", fmtInt(ms),
            },
            function(ok, message)
                if not ok then notifyError(body.req, message) end
            end
        )

    elseif kind == "page" then
        enqueueWrite(
            { "upsert", "page", "--page", text },
            function(ok, message)
                if ok then
                    openLogseqUrl("page=" .. urlEncode(text))
                else
                    notifyError(body.req, message)
                end
            end
        )
    end
end


-- ============================================================
-- WINDOW POSITION
-- ============================================================

local function positionPopup(height)
    if not S.popup then
        return
    end

    local screen =
        hs.mouse.getCurrentScreen()
        or hs.screen.mainScreen()

    if not screen then
        return
    end

    local frame = screen:frame()

    local maxHeight = math.min(MAX_HEIGHT, frame.h - SCREEN_MARGIN * 2)

    height =
        math.max(
            MIN_HEIGHT,
            math.min(maxHeight, tonumber(height) or MIN_HEIGHT)
        )

    S.popup:frame({
        x = frame.x + frame.w - WIDTH - SCREEN_MARGIN,
        y = frame.y + frame.h - height - SCREEN_MARGIN,
        w = WIDTH,
        h = height,
    })
end


-- ============================================================
-- HIDE
-- ============================================================

local function hideCapture()
    if not S.popup or not S.visible then
        return
    end

    S.visible = false
    S.pendingShow = false
    S.canBlurClose = false
    S.blurPinned = false

    S.popup:hide()

    -- Re-arm only after pointer leaves the corner.
    S.cornerArmed = false

    hs.timer.doAfter(0.25, updatePeek)
end


-- ============================================================
-- WEB UI (logseq_capture/web/)
-- ============================================================

local assets = require("logseq_capture.assets")
local html = assets.page("panel.html")
local peekHtml = assets.page("peek.html")


-- ============================================================
-- CREATE / SHOW WEBVIEW
-- ============================================================

local showCapture


local function onPanelMessage(message)
    local body = message.body

    if type(body) ~= "table" then
        return
    end

    local action = body.action

    if action == "ready" then
        S.ready = true
        jsPanel("app.setDashboard(" .. hs.json.encode({ page = DASHBOARD_PAGE or "" }) .. ")")
        applyData()

        if S.pendingShow then
            S.pendingShow = false
            hs.timer.doAfter(0, function() showCapture() end)
        end

    elseif action == "resize" then
        S.lastHeight = tonumber(body.height) or S.lastHeight

        if S.visible then
            positionPopup(S.lastHeight)
        end

    elseif action == "close" then
        hideCapture()

    elseif action == "capture" then
        local kind = body.kind

        if kind == "note" or kind == "backlog" or kind == "page" then
            -- Web animation already finished.
            hideCapture()
        end

        hs.timer.doAfter(0.01, function() handleCapture(body) end)

    elseif action == "update" then
        handleUpdate(body)

    elseif action == "refresh" then
        requestRefresh()

    elseif action == "pinBlur" then
        S.blurPinned = body.on == true

    elseif action == "openUrl" then
        local url = tostring(body.url or "")

        if url:match("^https?://") then
            hideCapture()
            hs.urlevent.openURL(url)
        end

    elseif action == "openBlock" then
        local uuid = tostring(body.uuid or "")

        if uuid:match("^[%x%-]+$") then
            hideCapture()
            openLogseqUrl("block-id=" .. uuid)
        end

    elseif action == "openPage" and DASHBOARD_PAGE then
        hideCapture()
        openLogseqUrl("page=" .. urlEncode(DASHBOARD_PAGE))
    end
end


local function createPopup()
    S.usercontent = hs.webview.usercontent.new("logseqCapture")

    S.usercontent:setCallback(function(message)
        local ok, err = pcall(onPanelMessage, message)

        if not ok then
            log("message error:", err)
        end
    end)

    S.popup = hs.webview.new(
        { x = 0, y = 0, w = WIDTH, h = MIN_HEIGHT },
        { javaScriptEnabled = true },
        S.usercontent
    )

    S.popup
        :windowStyle({ "borderless" })
        :allowTextEntry(true)
        :transparent(true)
        :shadow(false)
        :closeOnEscape(false)
        :level(hs.drawing.windowLevels.floating)

    -- Click anywhere outside → close.
    S.popup:windowCallback(function(action, _, state)
        if action == "focusChange"
            and state == false
            and S.visible
            and S.canBlurClose
            and not S.blurPinned
        then
            hideCapture()
        end
    end)

    -- Preload while hidden.
    S.popup:html(html)
end


local function createPeek()
    if not SHOW_PEEK then
        return
    end

    S.peekContent = hs.webview.usercontent.new("logseqPeek")

    S.peekContent:setCallback(function(message)
        local body = message.body

        if type(body) ~= "table" then
            return
        end

        if body.action == "ready" then
            S.peekReady = true
            updatePeek()
        elseif body.action == "expand" then
            showCapture()
        elseif body.action == "hoverHidden" and S.peekHovered then
            -- Hiding the native window lets clicks reach the app underneath.
            S.peek:hide()
            S.peekVisible = false
        end
    end)

    S.peek = hs.webview.new(
        { x = 0, y = 0, w = PEEK_WIDTH, h = peekHeight(1) },
        { javaScriptEnabled = true },
        S.peekContent
    )

    -- "nonactivating" keeps the peek from stealing focus.
    local okStyle = pcall(function()
        S.peek:windowStyle({ "borderless", "nonactivating" })
    end)

    if not okStyle then
        S.peek:windowStyle({ "borderless" })
    end

    S.peek
        :transparent(true)
        :shadow(false)
        :closeOnEscape(false)
        :level(hs.drawing.windowLevels.floating)

    S.peek:html(peekHtml)
end


showCapture = function()
    if S.visible then
        return
    end

    if not S.popup then
        createPopup()
    end

    if not S.ready then
        S.pendingShow = true
        return
    end

    S.visible = true
    S.canBlurClose = false

    hidePeek()

    positionPopup(S.lastHeight)

    S.popup:show()
    S.popup:bringToFront(true)

    local window = S.popup:hswindow()

    if window then
        window:focus()
    end

    -- Prevent initial focus transition from closing it.
    hs.timer.doAfter(0.20, function()
        if S.visible then
            S.canBlurClose = true
        end
    end)

    hs.timer.doAfter(0.04, function()
        if S.popup and S.visible then
            jsPanel("app.reset()")
        end
    end)

    requestRefresh()
end


local function toggleCapture()
    if S.visible then
        jsPanel("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}))")
    else
        showCapture()
    end
end


-- ============================================================
-- START
-- ============================================================

rollDone()

S.env = captureUserEnv()

if not S.env then
    log("could not capture user env — falling back to " .. USER_SHELL .. " -l -i -c")
end

createPopup()
createPeek()

if OPEN_HOTKEY then
    S.hotkey = hs.hotkey.bind(OPEN_HOTKEY[1], OPEN_HOTKEY[2], toggleCapture)
end

-- Background refresh keeps the peek honest (and catches day change).
S.refreshTimer = hs.timer.doEvery(REFRESH_INTERVAL, function()
    if SHOW_PEEK or S.visible then
        requestRefresh()
    end
end)

requestRefresh()


-- ============================================================
-- HOT CORNER
-- ============================================================

S.cornerTimer = hs.timer.doEvery(0.10, function()
    local position = hs.mouse.absolutePosition()
    updatePeekHover(position)
    local screen = hs.mouse.getCurrentScreen()

    if not screen then
        return
    end

    local frame = screen:fullFrame()

    local right = (frame.x + frame.w) - position.x
    local bottom = (frame.y + frame.h) - position.y

    -- Leave corner → allow next trigger.
    if right > REARM_DISTANCE or bottom > REARM_DISTANCE then
        S.cornerArmed = true
    end

    -- Hit bottom-right corner.
    if S.cornerArmed
        and not S.visible
        and right >= 0
        and bottom >= 0
        and right <= CORNER_SIZE
        and bottom <= CORNER_SIZE
    then
        S.cornerArmed = false
        showCapture()
    end
end)


log("loaded — panel + peek, async CLI (" .. (S.env and "direct" or "shell") .. ")")

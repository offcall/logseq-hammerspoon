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
-- PANEL HTML
-- ============================================================

local html = [==[
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="dark light">
<style>
:root {
    color-scheme: dark;
    --panel: rgba(28, 28, 31, .97);
    --panel-border: rgba(255,255,255,.14);
    --field: rgba(255,255,255,.055);
    --field-focus: rgba(255,255,255,.075);
    --text: rgba(255,255,255,.92);
    --text-2: rgba(255,255,255,.78);
    --muted: rgba(255,255,255,.50);
    --faint: rgba(255,255,255,.36);
    --line: rgba(255,255,255,.08);
    --hover: rgba(255,255,255,.055);
    --btn: rgba(255,255,255,.055);
    --btn-border: rgba(255,255,255,.09);
    --sel: rgba(10,132,255,.14);
    --sel-border: rgba(10,132,255,.45);
    --blue: #0a84ff;
    --blue-text: #78b4ff;
    --orange: #f5a524;
    --red: #ff6b5e;
    --toast-bg: rgba(242,242,244,.97);
    --toast-text: #141416;
}

@media (prefers-color-scheme: light) {
    :root {
        color-scheme: light;
        --panel: rgba(248,248,250,.97);
        --panel-border: rgba(0,0,0,.10);
        --field: rgba(0,0,0,.035);
        --field-focus: rgba(0,0,0,.045);
        --text: rgba(0,0,0,.87);
        --text-2: rgba(0,0,0,.74);
        --muted: rgba(0,0,0,.52);
        --faint: rgba(0,0,0,.38);
        --line: rgba(0,0,0,.08);
        --hover: rgba(0,0,0,.04);
        --btn: rgba(0,0,0,.045);
        --btn-border: rgba(0,0,0,.08);
        --sel: rgba(10,132,255,.10);
        --sel-border: rgba(10,132,255,.40);
        --blue-text: #0a63c9;
        --orange: #c77700;
        --red: #d63a2c;
        --toast-bg: rgba(28,28,31,.96);
        --toast-text: #f2f2f4;
    }
}

* { box-sizing: border-box; }

html, body {
    margin: 0;
    width: 100%;
    height: 100%;
    overflow: hidden;
    background: transparent !important;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    -webkit-font-smoothing: antialiased;
}

body {
    padding: 8px;
    user-select: none;
    -webkit-user-select: none;
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
}

.capture {
    position: relative;
    width: 100%;
    max-height: 100%;
    display: flex;
    flex-direction: column;
    padding: 14px 14px 10px;
    border-radius: 18px;
    border: 1px solid var(--panel-border);
    background: var(--panel);
    /* backdrop-filter can't see other apps through a WKWebView window,
       so it only produced a flat translucent layer — dropped. */
    box-shadow: 0 2px 6px rgba(0,0,0,.28), 0 1px 0 rgba(255,255,255,.05) inset;
    background-clip: padding-box;
    transform-origin: 92% 100%;
    will-change: transform, opacity;
    color: var(--text);
    font-size: 13px;
}

.capture.closing { pointer-events: none; }

/* header */
.top {
    height: 24px;
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 10px;
    padding: 0 2px;
}
.brand {
    display: flex; align-items: center; gap: 8px;
    font-size: 13px; font-weight: 600; letter-spacing: -.15px;
}
.brand .date { color: var(--muted); font-weight: 500; }
.dot {
    width: 9px; height: 9px; border-radius: 50%;
    background: rgba(174,174,178,.9);
    transition: background .2s;
}
.dot.loading { background: var(--blue); animation: pulse 1s ease-in-out infinite; }
.dot.error { background: var(--red); }
.top-right {
    display: flex; align-items: center; gap: 7px;
    color: var(--muted); font-size: 11px;
}
.linkbtn {
    appearance: none; border: 0; background: none; padding: 2px 0;
    color: var(--muted); font: inherit; font-size: 11px; cursor: default;
    display: inline-flex; align-items: center; gap: 6px;
}
.linkbtn:hover { color: var(--text); }
.top-right .sep { width: 1px; height: 12px; background: var(--line); margin: 0 3px; }
.top-right [hidden] { display: none; }

/* keycaps */
.key {
    min-width: 22px; height: 20px; padding: 0 5px;
    display: inline-flex; align-items: center; justify-content: center;
    border-radius: 6px;
    border: 1px solid var(--btn-border);
    background: var(--btn);
    color: var(--muted);
    font-size: 10px; line-height: 1;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
}

/* input */
textarea {
    display: block; flex: 0 0 auto;
    width: 100%; min-height: 46px; max-height: 160px;
    resize: none; overflow-y: hidden;
    border: 1px solid var(--btn-border);
    border-radius: 12px; outline: none;
    padding: 12px 13px;
    background: var(--field); color: var(--text);
    caret-color: var(--blue);
    font: inherit; font-size: 13px; line-height: 20px;
    user-select: text; -webkit-user-select: text;
    transition: border-color .12s ease, background .12s ease, box-shadow .12s ease;
}
textarea::placeholder { color: var(--faint); }
textarea:focus {
    border-color: rgba(10,132,255,.60);
    background: var(--field-focus);
    box-shadow: 0 0 0 3px rgba(10,132,255,.12);
}

/* capture actions */
.actions {
    flex: 0 0 auto;
    display: grid;
    grid-template-columns: repeat(6, minmax(0, 1fr));
    gap: 6px; margin-top: 8px;
}
.actions button {
    appearance: none; height: 30px; padding: 0 6px;
    display: flex; align-items: center; justify-content: center; gap: 5px;
    border: 1px solid var(--btn-border); border-radius: 9px;
    background: var(--btn); color: var(--text-2);
    font: inherit; font-size: 12px; font-weight: 500;
    cursor: default; white-space: nowrap;
    transition: background .1s ease, border-color .1s ease;
}
.actions button:hover { background: var(--hover); border-color: var(--panel-border); color: var(--text); }
.actions button:active { background: rgba(255,255,255,.13); }
.actions button.primary { background: rgba(10,132,255,.16); border-color: rgba(10,132,255,.34); }
.actions button.primary:hover { background: rgba(10,132,255,.23); }
.actions svg { flex: 0 0 auto; opacity: .8; }
.actions button.on { background: var(--sel); border-color: var(--sel-border); color: var(--text); }

/* date picker */
.picker {
    flex: 0 0 auto;
    margin-top: 8px; padding: 8px; border-radius: 12px;
    border: 1px solid var(--panel-border); background: var(--field);
}
.picker[hidden] { display: none; }
.picker-opts { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 4px; }
.picker-opts .opt {
    flex-direction: row; align-items: baseline; justify-content: space-between; gap: 6px;
    padding: 4px 8px; white-space: nowrap;
}
.opt.sel { border-color: var(--sel-border); background: var(--sel); }
.cal { margin-top: 8px; padding: 8px 2px 0; border-top: 1px solid var(--line); }
.cal-head {
    display: flex; align-items: center; justify-content: space-between;
    padding: 0 4px 6px; font-size: 12px; font-weight: 600;
}
.cal-nav {
    appearance: none; border: 0; background: none; padding: 0 6px;
    color: var(--muted); font: inherit; font-size: 14px; cursor: default;
}
.cal-nav:hover:not(:disabled) { color: var(--text); }
.cal-nav:disabled { opacity: .3; }
.cal-grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 2px; text-align: center; }
.cal-dw { font-size: 10px; color: var(--faint); padding: 2px 0 4px; }
.cal-day {
    appearance: none; height: 26px; padding: 0;
    border: 0; border-radius: 7px; background: none;
    color: var(--text-2); font: inherit; font-size: 12px;
    font-variant-numeric: tabular-nums; cursor: default;
}
.cal-day:hover:not(:disabled) { background: var(--hover); }
.cal-day:disabled { color: var(--faint); opacity: .5; }
.cal-day.today { color: var(--blue-text); font-weight: 700; }
.cal-day.cur { background: var(--blue); color: #fff; font-weight: 600; }

/* progress */
.task-tools {
    flex: 0 0 auto;
    display: flex; align-items: center; gap: 8px;
    margin: 12px 2px 6px;
}
.progress {
    flex: 1;
    display: flex; align-items: center; gap: 10px;
}
.bar { flex: 1; height: 3px; border-radius: 3px; background: var(--line); overflow: hidden; }
.bar > i { display: block; height: 100%; width: 0; background: var(--blue); border-radius: 3px; transition: width .3s ease; }
.progress .txt { font-size: 11px; color: var(--muted); font-variant-numeric: tabular-nums; }

.view-btn {
    appearance: none; border: 0; background: none; padding: 0;
    display: flex; align-items: center; justify-content: center;
    width: 24px; height: 24px; border-radius: 6px;
    color: var(--muted); cursor: default;
}
.view-btn:hover { background: var(--hover); color: var(--text); }
.view-btn.on { background: var(--sel); color: var(--blue-text); }

/* calendar grid */
.days { flex: 0 0 auto; margin: 0 0 4px; }
.days[hidden] { display: none; }
.days-grid { display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); gap: 3px; }
.days-dw { font-size: 9px; color: var(--faint); text-align: center; text-transform: uppercase; padding-bottom: 1px; }
.day {
    appearance: none; position: relative; height: 40px; padding: 3px 5px;
    display: flex; flex-direction: column; align-items: flex-start;
    border: 1px solid transparent; border-radius: 7px; background: var(--btn);
    color: var(--muted); font: inherit; font-size: 10px; text-align: left; cursor: default;
}
.day:hover { background: var(--hover); }
.day b { font-size: 12px; line-height: 15px; font-weight: 600; color: var(--text); font-variant-numeric: tabular-nums; }
.day.we { opacity: .6; }
.day.past { opacity: .4; }
.day.today b { color: var(--blue-text); }
.day.sel { background: var(--sel); border-color: var(--sel-border); opacity: 1; }
.day .late { position: absolute; right: 4px; top: 3px; color: var(--red); font-weight: 600; }
.day .load { position: absolute; left: 5px; right: 5px; bottom: 4px; height: 3px; border-radius: 2px; background: var(--line); overflow: hidden; }
.day .load i { display: block; height: 100%; border-radius: 2px; background: var(--blue); }
.day .load i.full { background: var(--orange); }
.sec .earlier {
    appearance: none; border: 0; background: none; padding: 0; margin-left: auto;
    color: var(--red); font: inherit; text-transform: none; letter-spacing: 0; font-weight: 500; cursor: default;
}
.sec .earlier:hover { text-decoration: underline; }

.search { display: flex; align-items: center; }
.search button {
    appearance: none; border: 0; background: none; padding: 0;
    display: flex; align-items: center; justify-content: center;
    width: 24px; height: 24px; border-radius: 6px;
    color: var(--muted); cursor: default;
}
.search button:hover { background: var(--hover); color: var(--text); }
.search input {
    width: 0; height: 24px; padding: 0; border: 0; outline: none;
    border-radius: 6px; background: none; color: var(--text);
    font: inherit; font-size: 12px; opacity: 0;
    user-select: text; -webkit-user-select: text;
    transition: width .15s ease, opacity .15s ease;
}
.search input::placeholder { color: var(--faint); }
.search.open button { display: none; }
.search.open input {
    width: 150px; padding: 0 8px; opacity: 1;
    border: 1px solid var(--sel-border); background: var(--field-focus);
}

.sort { position: relative; margin-left: auto; }
.sort summary {
    list-style: none; display: flex; align-items: center; justify-content: center;
    width: 24px; height: 24px; border-radius: 6px;
    color: var(--muted); cursor: default;
}
.sort summary::-webkit-details-marker { display: none; }
.sort summary:hover, .sort[open] summary { background: var(--hover); color: var(--text); }
.sort-menu {
    position: absolute; right: 0; bottom: 28px; z-index: 10;
    width: 230px; padding: 5px; border-radius: 10px;
    border: 1px solid var(--panel-border); background: var(--panel);
    box-shadow: 0 6px 20px rgba(0,0,0,.25);
}
.sort-menu button {
    appearance: none; display: flex; align-items: center; gap: 8px;
    width: 100%; padding: 7px 8px; border: 0; border-radius: 6px;
    background: none; color: var(--text-2); font: inherit; font-size: 12px;
    text-align: left; cursor: default;
}
.sort-menu button:hover, .sort-menu button:focus-visible { background: var(--hover); }
.sort-menu button::before { content: ''; width: 12px; flex: 0 0 auto; }
.sort-menu button[aria-checked=true]::before { content: '✓'; color: var(--blue-text); }

/* list */
.list {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    margin: 0 -6px;
    padding: 0 6px 4px;
    outline: none;
    scrollbar-width: thin;
}
.list::-webkit-scrollbar { width: 6px; }
.list::-webkit-scrollbar-thumb { background: var(--line); border-radius: 3px; }

.sec {
    appearance: none; border: 0; background: none;
    display: flex; align-items: center; gap: 7px;
    width: 100%; padding: 10px 6px 4px;
    color: var(--muted); font: inherit;
    font-size: 10.5px; font-weight: 650; letter-spacing: .07em; text-transform: uppercase;
    cursor: default; text-align: left;
}
button.sec:hover { color: var(--text); }
.sec .n { color: var(--faint); font-weight: 600; }
.sec.red { color: var(--red); }
.sec.orange { color: var(--orange); }
.sec .chev { width: 10px; display: inline-flex; justify-content: center; }
.sec .pdot { width: 6px; height: 6px; border-radius: 50%; background: var(--orange); animation: pulse 1.8s ease-in-out infinite; }

.row {
    position: relative;
    display: flex; gap: 9px; align-items: flex-start;
    padding: 7px 6px;
    border-radius: 10px;
    border: 1px solid transparent;
}
.row:hover { background: var(--hover); }
.row.sel { background: var(--sel); border-color: var(--sel-border); }
.row.pending { opacity: .55; }

.circ {
    appearance: none; flex: 0 0 auto;
    width: 22px; height: 22px; margin-top: -1px;
    display: flex; align-items: center; justify-content: center;
    border: 0; border-radius: 50%; background: none; padding: 0;
    color: var(--faint); cursor: default;
}
.circ:hover { background: var(--hover); color: var(--text); }
.row.st-doing .circ { color: var(--orange); }
.row.exp .circ { color: var(--red); }

.body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; padding-top: 1px; }
.ttl {
    color: var(--text); line-height: 18px;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
    word-break: break-word;
}
.row.is-done .ttl { text-decoration: line-through; color: var(--muted); }
.meta { display: flex; gap: 5px; flex-wrap: wrap; }
.chip {
    appearance: none; border: 0; font: inherit;
    font-size: 10.5px; line-height: 16px;
    padding: 0 6px; border-radius: 5px;
    background: var(--btn); color: var(--muted);
    cursor: default; white-space: nowrap;
    max-width: 220px; overflow: hidden; text-overflow: ellipsis;
}
button.chip:hover { color: var(--text); background: var(--hover); }
.chip.red { color: var(--red); background: rgba(255,107,94,.12); }
.chip.orange { color: var(--orange); background: rgba(245,165,36,.12); }
.chip.blue { color: var(--blue-text); background: rgba(10,132,255,.12); }

.acts {
    flex: 0 0 auto;
    display: flex; gap: 1px;
    opacity: 0; transition: opacity .1s ease;
    margin: -3px -2px -3px 0;
}
.row:hover .acts, .row.sel .acts { opacity: 1; }
.ib {
    appearance: none; width: 26px; height: 26px; padding: 0;
    display: flex; align-items: center; justify-content: center;
    border: 0; border-radius: 7px; background: none;
    color: var(--muted); cursor: default;
}
.ib:hover { background: var(--hover); color: var(--text); }
.ib.go:hover { color: var(--orange); }
.ib.ok:hover { color: var(--blue-text); }

.menu {
    display: grid; grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 5px; margin: 2px 6px 6px 37px;
}
.opt {
    appearance: none; position: relative;
    display: flex; flex-direction: column; align-items: flex-start; gap: 1px;
    padding: 6px 8px; border-radius: 8px;
    border: 1px solid var(--btn-border); background: var(--btn);
    color: var(--text); font: inherit; font-size: 12px; text-align: left;
    cursor: default; overflow: hidden;
}
.opt:hover, .opt:focus-within { border-color: var(--sel-border); background: var(--sel); }
.opt .hint { font-size: 10.5px; color: var(--muted); }
.opt input[type=date] {
    position: absolute; inset: 0; width: 100%; height: 100%;
    opacity: 0; border: 0; padding: 0; margin: 0;
}

.empty { padding: 14px 8px; color: var(--muted); font-size: 12.5px; }
.empty button { appearance: none; border: 0; background: none; color: var(--blue-text); font: inherit; padding: 0; cursor: default; }

/* footer */
.foot {
    flex: 0 0 auto;
    display: flex; align-items: center; justify-content: space-between; gap: 6px;
    margin-top: 6px; padding: 8px 2px 0;
    border-top: 1px solid var(--line);
    font-size: 10.5px; color: var(--muted);
    white-space: nowrap; overflow: hidden;
}
.foot .h { display: inline-flex; align-items: center; gap: 4px; }
.foot .key { min-width: 18px; height: 17px; font-size: 9.5px; padding: 0 4px; }
.foot .sp { flex: 1; }

/* toast */
.toast {
    position: absolute; left: 50%; bottom: 44px;
    transform: translate(-50%, 8px);
    display: flex; align-items: center; gap: 12px;
    padding: 7px 8px 7px 12px; border-radius: 10px;
    background: var(--toast-bg); color: var(--toast-text);
    font-size: 12.5px; white-space: nowrap;
    box-shadow: 0 10px 30px rgba(0,0,0,.35);
    opacity: 0; pointer-events: none;
    transition: opacity .15s ease, transform .15s ease;
    max-width: calc(100% - 28px);
}
.toast.show { opacity: 1; transform: translate(-50%, 0); pointer-events: auto; }
.toast.err { background: #b3261e; color: #fff; }
.toast .msg { overflow: hidden; text-overflow: ellipsis; }
.toast button {
    appearance: none; border: 0; border-radius: 6px;
    padding: 3px 8px; font: inherit; font-size: 12px; font-weight: 600;
    background: rgba(128,128,128,.22); color: inherit; cursor: default;
}

@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: .4; } }

@media (prefers-reduced-motion: reduce) {
    * { animation-duration: .001ms !important; transition-duration: .001ms !important; }
}
</style>
</head>
<body>

<div class="capture" id="capture">

    <div class="top">
        <div class="brand">
            <span class="dot" id="dot"></span>
            <span>Logseq</span>
            <span class="date" id="date"></span>
        </div>
        <div class="top-right">
            <button class="linkbtn" id="dashBtn" title="Open Dashboard in Logseq">Dashboard ↗</button>
            <span class="sep"></span>
            <button class="linkbtn" id="closeBtn">close <span class="key">esc</span></button>
        </div>
    </div>

    <textarea id="input" rows="1" placeholder="Write something…" spellcheck="true" autofocus></textarea>

    <div class="actions">
        <button class="primary" data-kind="note" title="Note → Journal (↩)">
            <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 13h3l7-7-3-3-7 7z"/></svg>Note
        </button>
        <button data-kind="today" title="Task for today (⌘T)">
            <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="8" cy="8" r="3"/><path d="M8 1.5v1.5M8 13v1.5M1.5 8H3M13 8h1.5M3.4 3.4l1 1M11.6 11.6l1 1M3.4 12.6l1-1M11.6 4.4l1-1"/></svg>Today
        </button>
        <button data-kind="tomorrow" title="Task for tomorrow (⌘⇧T)">
            <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8h9M8.5 4.5 12 8l-3.5 3.5"/></svg>Tmrw
        </button>
        <button data-kind="date" id="dateBtn" title="Task for a date (⌘D)">
            <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><rect x="2.5" y="3.5" width="11" height="10" rx="2"/><path d="M2.5 6.5h11M5.5 2v3M10.5 2v3"/></svg>Date
        </button>
        <button data-kind="backlog" title="Backlog task (⌘B)">
            <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M2.5 9.5h3l1 1.5h3l1-1.5h3V13h-11z M2.5 9.5 4 4h8l1.5 5.5"/></svg>Backlog
        </button>
        <button data-kind="page" title="New page (⌘P)">
            <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M4 2h5l3 3v9H4z M9 2v3h3"/></svg>Page
        </button>
    </div>

    <div class="picker" id="picker" hidden></div>

    <div class="task-tools" id="taskTools">
        <div class="progress" id="prog">
            <div class="bar"><i id="progBar"></i></div>
            <span class="txt" id="progTxt"></span>
        </div>
        <div class="search" id="search">
            <button id="searchBtn" title="Search tasks (⌘F)" aria-label="Search tasks">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5 14 14"/></svg>
            </button>
            <input id="searchInput" type="text" placeholder="Search tasks…" spellcheck="false" aria-label="Search tasks">
        </div>
        <button class="view-btn" id="viewBtn" title="Calendar (c)" aria-label="Toggle calendar">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><rect x="2.5" y="3.5" width="11" height="10" rx="2"/><path d="M2.5 6.5h11M5.5 2v3M10.5 2v3"/></svg>
        </button>
        <details class="sort" id="sortMenu">
            <summary title="Sort tasks" aria-label="Sort tasks">
                <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M2 4h7M2 8h5M2 12h3M12 3v10M9.5 10.5 12 13l2.5-2.5"/></svg>
            </summary>
            <div class="sort-menu" role="menu" aria-label="Sort tasks">
                <button role="menuitemradio" aria-checked="true" data-sort="modified-asc">Modified date · oldest first</button>
                <button role="menuitemradio" aria-checked="false" data-sort="modified-desc">Modified date · newest first</button>
                <button role="menuitemradio" aria-checked="false" data-sort="title-asc">Title · A–Z</button>
                <button role="menuitemradio" aria-checked="false" data-sort="title-desc">Title · Z–A</button>
            </div>
        </details>
    </div>

    <div class="days" id="days" hidden></div>

    <div class="list" id="list" tabindex="-1"></div>

    <div class="foot" id="foot"></div>

    <div class="toast" id="toast"></div>
</div>

<script>
(function () {
'use strict';

/* ======================================================== */
/* DOM / STATE                                              */
/* ======================================================== */

const $ = id => document.getElementById(id);
const capture = $('capture');
const input = $('input');
const listEl = $('list');
const footEl = $('foot');
const toastEl = $('toast');
const dotEl = $('dot');
const dateEl = $('date');
const progEl = $('prog');
const progBar = $('progBar');
const progTxt = $('progTxt');
const taskTools = $('taskTools');
const sortMenu = $('sortMenu');
const pickerEl = $('picker');
const daysEl = $('days');
const viewBtn = $('viewBtn');
const dateBtn = $('dateBtn');
const searchEl = $('search');
const searchInput = $('searchInput');

const DAY = 86400000;

const st = {
    tasks: [],
    temps: [],
    done: [],
    bounds: null,
    loaded: false,
    loading: false,
    error: null,
    sel: null,
    menu: null,
    picker: null,
    view: 'list',
    calDay: null,
    sort: 'modified-asc',
    query: '',
    collapsed: { tomorrow: true, done: true },
    undo: null,
    closing: false,
    lastHeight: 0,
    req: 0,
    order: [],
    secOf: {},
    toastTimer: 0
};

function post(message) {
    try {
        window.webkit.messageHandlers.logseqCapture.postMessage(message);
    } catch (error) {
        console.error(error);
    }
}

const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ======================================================== */
/* DATES                                                    */
/* ======================================================== */

function dayStart(ms) {
    const d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}
function addDays(ms, n) {
    const d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n).getTime();
}
function bounds() {
    if (st.bounds && st.bounds.start) return st.bounds;
    const s = dayStart(Date.now());
    return { start: s, end: addDays(s, 1), end2: addDays(s, 2), until: addDays(weekStart(s), 14) };
}
// Monday of the week that contains ms.
function weekStart(ms) {
    return addDays(dayStart(ms), -((new Date(ms).getDay() + 6) % 7));
}
function todayStart() { return bounds().start; }
function fmtDay(ms) {
    return new Date(ms).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
}
function isoDate(ms) {
    const d = new Date(ms);
    const p = n => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}
function monthStart(ms) {
    const d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), 1).getTime();
}
function dayLabel(ms) {
    const s = todayStart();
    if (ms === s) return 'Today';
    if (ms === addDays(s, 1)) return 'Tomorrow';
    return fmtDay(ms);
}

/* ======================================================== */
/* NORMALIZATION                                            */
/* ======================================================== */

function g(o, k) {
    if (!o || typeof o !== 'object') return undefined;
    if (k in o) return o[k];
    if ((':' + k) in o) return o[':' + k];
    return undefined;
}
function identTail(v) {
    if (v && typeof v === 'object') v = g(v, 'db/ident');
    if (!v) return '';
    v = String(v).replace(/^:/, '');
    const i = v.lastIndexOf('.');
    return i >= 0 ? v.slice(i + 1) : v;
}
function num(v) {
    if (typeof v === 'number' && isFinite(v)) return v;
    if (typeof v === 'string' && /^\d+$/.test(v)) return Number(v);
    return null;
}

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

function parseTitle(raw, refs) {
    let text = String(raw || '');
    const map = {};
    (Array.isArray(refs) ? refs : []).forEach(r => {
        const u = g(r, 'block/uuid') || r.uuid;
        const t = g(r, 'block/title') || r.title;
        if (u && t) map[String(u).toLowerCase()] = String(t);
    });
    const links = [];
    text = text.replace(new RegExp('\\[\\[(' + UUID + ')\\]\\]', 'gi'), (m, u) => map[u.toLowerCase()] || '…');
    text = text.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, (m, label, url) => { links.push(url); return label; });
    text = text.replace(/\[\[([^\]]+)\]\]/g, '$1');
    text = text.replace(/https?:\/\/[^\s<>()\[\]]+/g, url => { links.push(url.replace(/[.,;:!?'"]+$/, '')); return ' '; });
    text = text.replace(/\s+/g, ' ').replace(/^[\s\-–—:·|]+|[\s\-–—:·|]+$/g, '').trim();
    const parsed = [];
    links.forEach(url => {
        try { parsed.push({ url: url, host: new URL(url).hostname.replace(/^www\./, '') }); } catch (e) { /* skip */ }
    });
    if (!text) text = parsed.length ? parsed[0].host : 'Untitled';
    return { text: text, links: parsed };
}

function normTask(p) {
    const t = {
        id: g(p, 'db/id'),
        uuid: g(p, 'block/uuid') ? String(g(p, 'block/uuid')) : '',
        status: identTail(g(p, 'logseq.property/status')),
        priority: identTail(g(p, 'logseq.property/priority')),
        modifiedAt: num(g(p, 'block/updated-at')),
        deadline: num(g(p, 'logseq.property/deadline')),
        scheduled: num(g(p, 'logseq.property/scheduled'))
    };
    const pt = parseTitle(g(p, 'block/title'), g(p, 'block/refs'));
    t.title = pt.text;
    t.links = pt.links;
    return t;
}

/* ======================================================== */
/* BUCKETS                                                  */
/* ======================================================== */

function datesOf(t) { return [t.deadline, t.scheduled].filter(v => v != null); }
function minDate(t) { const d = datesOf(t); return d.length ? Math.min.apply(null, d) : Infinity; }

function bucketOf(t) {
    const b = bounds();
    const ds = datesOf(t);
    if (t.status === 'done') return null;
    if (t.status === 'doing') return 'doing';
    if (ds.some(d => d >= b.start && d < b.end)) return 'today';
    if (ds.some(d => d < b.start)) return 'expired';
    if (ds.some(d => d >= b.end && d < b.end2)) return 'tomorrow';
    return null;
}

function sortTasks(a, b) {
    const title = String(a.title).localeCompare(String(b.title), undefined, { sensitivity: 'base' });
    if (st.sort.startsWith('title-')) return st.sort === 'title-desc' ? -title : title;
    const da = num(a.modifiedAt), db = num(b.modifiedAt);
    if (da == null && db != null) return 1;
    if (db == null && da != null) return -1;
    if (da != null && db != null && da !== db) return st.sort === 'modified-desc' ? db - da : da - db;
    return title;
}

function groups() {
    const gr = { expired: [], doing: [], today: [], tomorrow: [] };
    st.tasks.concat(st.temps).forEach(t => {
        const b = bucketOf(t);
        if (b && gr[b]) gr[b].push(t);
    });
    Object.keys(gr).forEach(k => gr[k].sort(sortTasks));
    return gr;
}

/* calendar: Monday-first grid of this week and the next */
const CAL_DAYS = 14;
function calStart() { return weekStart(todayStart()); }
function calDay() {
    const d = st.calDay;
    return d != null && d >= calStart() && d < addDays(calStart(), CAL_DAYS) ? d : todayStart();
}
// A task belongs to the day of its earliest date (deadline or scheduled).
function dayOfTask(t) {
    const m = minDate(t);
    return m === Infinity ? null : dayStart(m);
}
function openOn(ms) {
    return st.tasks.concat(st.temps).filter(t => t.status !== 'done' && dayOfTask(t) === ms).sort(sortTasks);
}

// Every word of the query must appear in the title (case-insensitive).
function matchesQuery(t) {
    const words = st.query.toLowerCase().split(/\s+/).filter(Boolean);
    const title = String(t.title).toLowerCase();
    return words.every(w => title.indexOf(w) >= 0);
}

function findTask(id) {
    id = String(id);
    return st.tasks.concat(st.temps).find(t => String(t.id) === id) || null;
}
function findDone(id) {
    id = String(id);
    return st.done.find(d => String(d.id) === id) || null;
}

/* ======================================================== */
/* ICONS                                                    */
/* ======================================================== */

const I = {
    todo: '<svg width="16" height="16" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="7.25" stroke="currentColor" stroke-width="1.5"/></svg>',
    review: '<svg width="16" height="16" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="7.25" stroke="currentColor" stroke-width="1.5" stroke-dasharray="2.5 2.5"/></svg>',
    doing: '<svg width="16" height="16" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="7.25" stroke="currentColor" stroke-width="1.5"/><path d="M9 1.75a7.25 7.25 0 0 1 0 14.5z" fill="currentColor"/></svg>',
    done: '<svg width="16" height="16" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="8" fill="#0a84ff"/><path d="M5.5 9.3l2.3 2.3 4.7-5" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    play: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><path d="M5 3.5l7 4.5-7 4.5z"/></svg>',
    pause: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M5.5 3.5v9M10.5 3.5v9"/></svg>',
    check: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>',
    next: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8h9M8.5 4.5L12 8l-3.5 3.5"/></svg>',
    back: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M13 8H4M7.5 4.5L4 8l3.5 3.5"/></svg>',
    cal: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><rect x="2.5" y="3.5" width="11" height="10" rx="2"/><path d="M2.5 6.5h11M5.5 2v3M10.5 2v3"/></svg>'
};

/* ======================================================== */
/* RENDER                                                   */
/* ======================================================== */

function circleFor(t, sec) {
    if (sec === 'done') return I.done;
    if (t.status === 'doing') return I.doing;
    if (t.status === 'in-review') return I.review;
    return I.todo;
}

function chipsFor(t, sec) {
    const c = [];
    if (sec === 'expired') {
        const days = Math.max(1, Math.round((todayStart() - dayStart(minDate(t))) / DAY));
        c.push('<span class="chip red">' + (days === 1 ? 'yesterday' : days + 'd overdue') + '</span>');
    }
    if (sec === 'doing') {
        const m = minDate(t);
        if (m !== Infinity) c.push('<span class="chip' + (m < todayStart() ? ' red' : '') + '">' + esc(dayLabel(dayStart(m))) + '</span>');
    }
    if (t.priority === 'urgent') c.push('<span class="chip red">Urgent</span>');
    else if (t.priority === 'high') c.push('<span class="chip orange">High</span>');
    if (t.status === 'in-review') c.push('<span class="chip blue">In review</span>');
    if (t.status === 'backlog' && sec !== 'done') c.push('<span class="chip">Backlog</span>');
    if (t.pending) c.push('<span class="chip">saving…</span>');
    (t.links || []).slice(0, 2).forEach(l => {
        c.push('<button class="chip" data-act="link" data-url="' + esc(l.url) + '" title="' + esc(l.url) + '">↗ ' + esc(l.host) + '</button>');
    });
    return c.length ? '<div class="meta">' + c.join('') + '</div>' : '';
}

function actsFor(t, sec) {
    if (t.pending || sec === 'done') return '';
    const b = (act, icon, label, cls) =>
        '<button class="ib' + (cls ? ' ' + cls : '') + '" data-act="' + act + '" title="' + label + '" aria-label="' + label + '">' + icon + '</button>';
    const out = [];
    if (sec === 'doing') out.push(b('pause', I.pause, 'Pause (s)'));
    else out.push(b('start', I.play, 'Start (s)', 'go'));
    out.push(b('done', I.check, 'Done (space)', 'ok'));
    if (sec === 'tomorrow') out.push(b('today', I.back, 'Back to today (t)'));
    else if (sec !== 'doing') out.push(b('tomorrow', I.next, 'Tomorrow (t)'));
    out.push(b('menu', I.cal, 'Reschedule (d)'));
    return '<div class="acts">' + out.join('') + '</div>';
}

function moveOptions(t) {
    const s = todayStart();
    const dow = new Date(s).getDay();
    const toMonday = ((8 - dow) % 7) || 7;
    const opts = [];
    if (bucketOf(t) !== 'today') opts.push({ act: 'move', ms: s, label: 'Today', hint: fmtDay(s) });
    if (bucketOf(t) !== 'tomorrow') opts.push({ act: 'move', ms: addDays(s, 1), label: 'Tomorrow', hint: fmtDay(addDays(s, 1)) });
    if (toMonday > 1) opts.push({ act: 'move', ms: addDays(s, toMonday), label: 'Monday', hint: fmtDay(addDays(s, toMonday)) });
    opts.push({ act: 'move', ms: addDays(s, 7), label: 'Next week', hint: fmtDay(addDays(s, 7)) });
    opts.push({ act: 'backlog', label: 'Backlog', hint: 'no date' });
    return opts;
}

function menuFor(t) {
    const opts = moveOptions(t);
    const html = opts.map((o, i) =>
        '<button class="opt" data-act="' + o.act + '" data-ms="' + (o.ms || '') + '">' +
        '<span>' + esc(o.label) + '</span><span class="hint">' + (i + 1) + ' · ' + esc(o.hint) + '</span></button>'
    ).join('');
    const pick =
        '<label class="opt"><span>Pick date…</span><span class="hint">' + (opts.length + 1) + ' · calendar</span>' +
        '<input type="date" data-act="pick" value="' + isoDate(addDays(todayStart(), 1)) + '" min="' + isoDate(todayStart()) + '"></label>';
    return '<div class="menu" data-for="' + esc(t.id) + '">' + html + pick + '</div>';
}

function rowFor(t, sec) {
    const id = String(t.id);
    st.order.push(id);
    st.secOf[id] = sec;
    const cls = ['row', 'st-' + (t.status || 'todo')];
    if (sec === 'expired') cls.push('exp');
    if (sec === 'done') cls.push('is-done');
    if (t.pending) cls.push('pending');
    if (st.sel === id) cls.push('sel');
    const circleAct = sec === 'done' ? 'undone' : 'cycle';
    const circleLabel = sec === 'done' ? 'Mark not done' : (t.status === 'doing' ? 'Mark done' : 'Start');
    let html =
        '<div class="' + cls.join(' ') + '" data-id="' + esc(id) + '">' +
        '<button class="circ" data-act="' + circleAct + '" title="' + circleLabel + '" aria-label="' + circleLabel + '">' + circleFor(t, sec) + '</button>' +
        '<div class="body" data-act="select" title="Double-click to open in Logseq"><div class="ttl">' + esc(t.title) + '</div>' + chipsFor(t, sec) + '</div>' +
        actsFor(t, sec) +
        '</div>';
    if (st.menu === id && sec !== 'done' && !t.pending) html += menuFor(t);
    return html;
}

function section(key, label, items, opts) {
    opts = opts || {};
    if (!items.length && !opts.always) return '';
    const collapsible = key in st.collapsed;
    // While searching, every section with matches is shown expanded.
    const collapsed = collapsible && st.collapsed[key] && !st.query;
    const head =
        (collapsible ? '<button class="sec ' + (opts.cls || '') + '" data-act="section" data-sec="' + key + '">' : '<div class="sec ' + (opts.cls || '') + '">') +
        (collapsible ? '<span class="chev">' + (collapsed ? '▸' : '▾') + '</span>' : '') +
        (opts.dot ? '<span class="pdot"></span>' : '') +
        esc(label) + ' <span class="n">' + items.length + '</span>' +
        (collapsible ? '</button>' : '</div>');
    if (collapsed) return head;
    if (!items.length) return head + '<div class="empty">' + (opts.empty || 'Nothing here.') + '</div>';
    return head + items.map(t => rowFor(t, key)).join('');
}

function renderDays() {
    const on = st.view === 'calendar' && st.loaded;
    daysEl.hidden = !on;
    viewBtn.classList.toggle('on', st.view === 'calendar');
    if (!on) { daysEl.innerHTML = ''; return; }
    const s = todayStart();
    const start = calStart();
    const sel = calDay();
    let cells = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map(d => '<span class="days-dw">' + d + '</span>').join('');
    for (let i = 0; i < CAL_DAYS; i++) {
        const ms = addDays(start, i);
        const n = openOn(ms).length;
        const cls = ['day'];
        if (i % 7 >= 5) cls.push('we');
        if (ms < s) cls.push('past');
        if (ms === s) cls.push('today');
        if (ms === sel) cls.push('sel');
        let inner = '<b>' + new Date(ms).getDate() + '</b>';
        if (ms < s) {
            if (n) inner += '<span class="late">' + n + '</span>';
        } else if (n) {
            inner += n + '<span class="load"><i' + (n >= 5 ? ' class="full"' : '') + ' style="width:' + Math.min(100, n * 20) + '%"></i></span>';
        }
        cells += '<button class="' + cls.join(' ') + '" data-day="' + ms + '" title="' + esc(fmtDay(ms)) + '">' + inner + '</button>';
    }
    daysEl.innerHTML = '<div class="days-grid">' + cells + '</div>';
}

function daySection(day, items, earlier) {
    const head = '<div class="sec' + (day < todayStart() && items.length ? ' red' : '') + '">' +
        esc(dayLabel(day)) + ' <span class="n">' + items.length + '</span>' +
        (earlier ? '<button class="earlier" data-act="list">' + earlier + ' earlier →</button>' : '') +
        '</div>';
    if (!items.length) return head + '<div class="empty">Nothing on this day.</div>';
    return head + items.map(t => rowFor(t, bucketOf(t) || 'later')).join('');
}

function render(opts) {
    opts = opts || {};
    const scrollTop = listEl.scrollTop;
    st.order = [];
    st.secOf = {};
    taskTools.style.display = st.loaded ? '' : 'none';

    const b = bounds();
    dateEl.textContent = new Date(b.start).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
    dotEl.className = 'dot' + (st.loading ? ' loading' : '') + (st.error ? ' error' : '');

    if (!st.loaded) {
        listEl.innerHTML = st.error
            ? '<div class="empty">Couldn’t load tasks: ' + esc(st.error) + ' <button data-act="retry">Retry</button></div>'
            : '<div class="empty">Loading tasks…</div>';
        progEl.style.display = 'none';
    } else {
        const gr = groups();
        const doneItems = st.done.map(d => ({ id: d.id, uuid: d.uuid, title: d.title, links: d.links || [], modifiedAt: d.modifiedAt, status: 'done' })).sort(sortTasks);

        const total = gr.expired.length + gr.doing.length + gr.today.length + doneItems.length;
        progEl.style.display = total ? '' : 'none';
        progBar.style.width = total ? Math.round(doneItems.length / total * 100) + '%' : '0';
        progTxt.textContent = doneItems.length + ' / ' + total + ' done';

        const searching = !!st.query.trim();
        const shown = items => searching ? items.filter(matchesQuery) : items;

        let html = '';
        if (st.error) html += '<div class="empty">Refresh failed: ' + esc(st.error) + ' <button data-act="retry">Retry</button></div>';
        if (st.view === 'calendar') {
            const day = calDay();
            const earlier = gr.expired.filter(t => dayOfTask(t) < calStart()).length;
            html += daySection(day, shown(openOn(day)), earlier);
            if (day === todayStart()) html += section('done', 'Done today', shown(doneItems));
        } else {
            html += section('expired', 'Expired', shown(gr.expired), { cls: 'red' });
            html += section('doing', 'In progress', shown(gr.doing), { cls: 'orange', dot: true });
            html += section('today', 'Today', shown(gr.today), {
                always: !searching,
                empty: gr.expired.length || gr.doing.length ? 'Nothing else for today.' : 'Nothing for today. Add one with ⌘T.'
            });
            html += section('tomorrow', 'Tomorrow', shown(gr.tomorrow));
            html += section('done', 'Done today', shown(doneItems));
        }
        if (searching && !st.order.length) html += '<div class="empty">No tasks match “' + esc(st.query.trim()) + '”.</div>';
        listEl.innerHTML = html;
    }

    if (st.sel != null && st.order.indexOf(st.sel) < 0) st.sel = null;
    if (st.menu != null && st.order.indexOf(st.menu) < 0) st.menu = null;

    renderDays();
    listEl.scrollTop = scrollTop;

    if (opts.scroll && st.sel != null) {
        const el = listEl.querySelector('.row[data-id="' + cssEsc(st.sel) + '"]');
        if (el) {
            const menu = el.nextElementSibling && el.nextElementSibling.classList.contains('menu') ? el.nextElementSibling : null;
            (menu || el).scrollIntoView({ block: 'nearest' });
            el.scrollIntoView({ block: 'nearest' });
        }
    }

    renderFoot();
    requestAnimationFrame(reportHeight);
}

function cssEsc(s) {
    return window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/"/g, '\\"');
}

function renderFoot() {
    const h = (k, label) => '<span class="h"><span class="key">' + k + '</span>' + label + '</span>';
    let html;
    if (st.picker) {
        html = h('1–6', 'quick') + h('←→↑↓', 'day') + h('↩', 'create') + h('esc', 'back to text');
    } else if (document.activeElement === input) {
        html = h('↩', 'note') + h('⌘T', 'today') + h('⌘⇧T', 'tmrw') + h('⌘B', 'backlog') + h('⌘P', 'page') + h('↓', 'tasks');
    } else if (document.activeElement === searchInput) {
        html = h('↓', 'tasks') + h('esc', 'clear') + h('⌘F', 'search');
    } else if (st.menu != null) {
        html = h('1–6', 'pick') + h('esc', 'cancel');
    } else if (st.view === 'calendar') {
        html = h('↑↓', 'move') + h('←→', 'day') + h('⇧←→', 'week') + h('␣', 'done') + h('D', 'date') + h('↩', 'open') + h('C', 'list');
    } else {
        html = h('↑↓', 'move') + h('␣', 'done') + h('S', 'start') + h('T', 'tmrw') + h('D', 'date') + h('B', 'backlog') + h('↩', 'open') + h('C', 'cal');
    }
    footEl.innerHTML = html;
}

/* ======================================================== */
/* HEIGHT                                                   */
/* ======================================================== */

function reportHeight() {
    const rect = capture.getBoundingClientRect();
    const natural = Math.ceil(rect.height - listEl.clientHeight + listEl.scrollHeight + 16);
    if (Math.abs(natural - st.lastHeight) >= 1) {
        st.lastHeight = natural;
        post({ action: 'resize', height: natural });
    }
}

function resizeInput() {
    input.style.height = '46px';
    input.style.height = Math.min(160, Math.max(46, input.scrollHeight)) + 'px';
    input.style.overflowY = input.scrollHeight > 160 ? 'auto' : 'hidden';
    requestAnimationFrame(reportHeight);
}

/* ======================================================== */
/* TOAST                                                    */
/* ======================================================== */

function toast(message, opts) {
    opts = opts || {};
    clearTimeout(st.toastTimer);
    toastEl.className = 'toast show' + (opts.error ? ' err' : '');
    toastEl.innerHTML = '<span class="msg">' + esc(message) + '</span>' +
        (opts.undo ? '<button data-act="undo">Undo ⌘Z</button>' : '') +
        (opts.retry ? '<button data-act="retry">Refresh</button>' : '');
    st.toastTimer = setTimeout(() => { toastEl.className = 'toast'; }, opts.error ? 6000 : 4000);
}

/* ======================================================== */
/* TASK ACTIONS                                             */
/* ======================================================== */

function sendUpdate(t, patch) {
    const m = {
        action: 'update',
        req: ++st.req,
        id: typeof t.id === 'number' ? t.id : Number(t.id),
        uuid: t.uuid || '',
        title: t.title || ''
    };
    if (patch.status) m.status = patch.status;
    ['deadline', 'scheduled'].forEach(f => {
        if (f in patch) {
            if (patch[f] == null) m[f + 'Mode'] = 'clear';
            else { m[f + 'Mode'] = 'set'; m[f] = patch[f]; }
        }
    });
    post(m);
}

// Move the task so its earliest date becomes `target` (local midnight).
function computeMove(t, target) {
    const present = ['deadline', 'scheduled'].filter(f => t[f] != null);
    if (!present.length) return { deadline: target };
    const cur = { deadline: t.deadline, scheduled: t.scheduled };
    present.forEach(f => { if (dayStart(cur[f]) < target) cur[f] = target; });
    let minF = present[0];
    present.forEach(f => { if (cur[f] < cur[minF]) minF = f; });
    if (dayStart(cur[minF]) > target) cur[minF] = target;
    const patch = {};
    present.forEach(f => { if (cur[f] !== t[f]) patch[f] = cur[f]; });
    return patch;
}

function keepSelectionNear(prevIndex) {
    if (st.sel != null && st.order.indexOf(st.sel) >= 0) return;
    if (!st.order.length) { st.sel = null; return; }
    st.sel = st.order[Math.min(Math.max(prevIndex, 0), st.order.length - 1)];
}

function act(id, kind, ms) {
    const t = findTask(id);
    if (!t || t.pending) return;

    const prevIndex = st.order.indexOf(String(id));
    const item = Object.assign({}, t);
    let patch, label;

    if (kind === 'start') { patch = { status: 'doing' }; label = 'Started'; }
    else if (kind === 'pause') { patch = { status: 'todo' }; label = 'Paused'; }
    else if (kind === 'done') { patch = { status: 'done' }; label = 'Done ✓'; }
    else if (kind === 'backlog') { patch = { status: 'backlog', deadline: null, scheduled: null }; label = 'Moved to Backlog'; }
    else if (kind === 'move') {
        if (!isFinite(ms)) return;
        patch = computeMove(t, ms);
        // moving an in-progress task to a later day pauses it
        if (t.status === 'doing' && ms > todayStart()) patch.status = 'todo';
        label = 'Moved to ' + dayLabel(ms);
        if (!Object.keys(patch).length) {
            st.menu = null;
            toast('Already on ' + dayLabel(ms));
            render();
            return;
        }
    } else return;

    const restore = {};
    Object.keys(patch).forEach(k => { restore[k] = item[k] == null ? null : item[k]; });
    t.modifiedAt = Date.now();

    if (patch.status === 'done') {
        st.tasks = st.tasks.filter(x => x !== t);
        st.done.unshift({ id: t.id, uuid: t.uuid, title: t.title, links: t.links, modifiedAt: t.modifiedAt });
    } else {
        Object.keys(patch).forEach(k => { t[k] = patch[k]; });
    }

    sendUpdate(t, patch);
    st.undo = { id: t.id, item: item, restore: restore };
    st.menu = null;
    render();
    keepSelectionNear(prevIndex);
    render({ scroll: true });
    toast(label, { undo: true });
}

function undone(id) {
    const d = findDone(id);
    if (!d) return;
    st.done = st.done.filter(x => x !== d);
    sendUpdate(d, { status: 'todo' });
    st.undo = { id: d.id, item: Object.assign({ status: 'done' }, d), restore: { status: 'done' } };
    render();
    toast('Back to todo — will reappear on refresh', { undo: true });
}

function cycle(id) {
    const t = findTask(id);
    if (!t) return;
    if (t.status === 'doing') act(id, 'done');
    else act(id, 'start');
}

function undo() {
    const u = st.undo;
    if (!u) { toast('Nothing to undo'); return; }
    st.undo = null;

    if (u.restore.status === 'done') {
        st.tasks = st.tasks.filter(x => String(x.id) !== String(u.id));
        if (!findDone(u.id)) st.done.unshift({ id: u.item.id, uuid: u.item.uuid, title: u.item.title, links: u.item.links, modifiedAt: Date.now() });
    } else {
        st.done = st.done.filter(x => String(x.id) !== String(u.id));
        let t = findTask(u.id);
        if (!t) { t = Object.assign({}, u.item); st.tasks.push(t); }
        Object.keys(u.restore).forEach(k => { t[k] = u.restore[k]; });
        t.modifiedAt = Date.now();
    }

    sendUpdate(u.item, u.restore);
    st.sel = String(u.id);
    render({ scroll: true });
    toast('Undone');
}

function toggleMenu(id) {
    id = String(id);
    st.sel = id;
    st.menu = st.menu === id ? null : id;
    render({ scroll: true });
}

function pickMenu(index) {
    const t = findTask(st.menu);
    if (!t) return;
    const opts = moveOptions(t);
    if (index < opts.length) {
        const o = opts[index];
        if (o.act === 'backlog') act(t.id, 'backlog');
        else act(t.id, 'move', o.ms);
    } else if (index === opts.length) {
        const dateInput = listEl.querySelector('.menu input[type=date]');
        if (dateInput) {
            dateInput.focus();
            try { dateInput.showPicker && dateInput.showPicker(); } catch (e) { /* not supported */ }
        }
    }
}

function openTask(id) {
    const t = findTask(id) || findDone(id);
    if (t && t.uuid) post({ action: 'openBlock', uuid: t.uuid });
}

// Selection only toggles a class. Rebuilding the list here would replace the
// row mid-gesture, so the second click never becomes a dblclick.
function paintSelection() {
    listEl.querySelectorAll('.row.sel').forEach(el => el.classList.remove('sel'));
    if (st.sel != null) {
        const el = listEl.querySelector('.row[data-id="' + cssEsc(st.sel) + '"]');
        if (el) el.classList.add('sel');
    }
    renderFoot();
}

function setView(view) {
    st.view = view;
    st.calDay = null;
    st.sel = null;
    st.menu = null;
    render();
    listEl.focus({ preventScroll: true });
}

function moveCalDay(delta) {
    const start = calStart();
    st.calDay = Math.min(addDays(start, CAL_DAYS - 1), Math.max(start, addDays(calDay(), delta)));
    st.sel = null;
    st.menu = null;
    render();
}

function select(id) {
    st.sel = id == null ? null : String(id);
    if (document.activeElement === input) input.blur();
    listEl.focus({ preventScroll: true });
    paintSelection();
}

function focusInput() {
    st.menu = null;
    input.focus();
    render();
}

/* ======================================================== */
/* CAPTURE                                                  */
/* ======================================================== */

function submit(kind, dateMs) {
    const text = input.value.trim();
    if (!text || st.closing) { input.focus(); return; }

    if (kind === 'today' || kind === 'tomorrow' || kind === 'date') {
        const tomorrow = addDays(todayStart(), 1);
        const ms = kind === 'date' ? dateMs : (kind === 'today' ? todayStart() : tomorrow);
        const req = ++st.req;
        const pt = parseTitle(text);
        // Tasks past the calendar window get just the toast.
        if (ms < bounds().until) {
            st.temps.push({ id: 'tmp' + req, req: req, pending: true, status: 'todo', priority: '', modifiedAt: Date.now(), deadline: ms, scheduled: null, title: pt.text, links: pt.links });
        }
        post({ action: 'capture', kind: kind, text: text, ms: ms, req: req });
        input.value = '';
        resizeInput();
        if (ms === tomorrow) st.collapsed.tomorrow = false;
        setPicker(null);
        render();
        toast(ms === todayStart() ? 'Added to Today' : (ms === tomorrow ? 'Added to Tomorrow' : 'Added for ' + fmtDay(ms)));
        return;
    }

    animateClose(() => {
        input.value = '';
        resizeInput();
        post({ action: 'capture', kind: kind, text: text });
    });
}

/* ======================================================== */
/* DATE PICKER                                              */
/* ======================================================== */

function nextWeekday(from, dow) {
    return addDays(from, ((dow - new Date(from).getDay() + 7) % 7) || 7);
}

function inAMonth(from) {
    const d = new Date(from);
    const lastDay = new Date(d.getFullYear(), d.getMonth() + 2, 0).getDate();
    return new Date(d.getFullYear(), d.getMonth() + 1, Math.min(d.getDate(), lastDay)).getTime();
}

function quickDates() {
    const s = todayStart();
    const opts = [
        { label: 'Today', ms: s },
        { label: 'Tomorrow', ms: addDays(s, 1) },
        { label: 'Friday', ms: nextWeekday(s, 5) },
        { label: 'Weekend', ms: nextWeekday(s, 6) },
        { label: 'Next week', ms: nextWeekday(s, 1) },
        { label: 'In a month', ms: inAMonth(s) }
    ];
    const seen = {};
    return opts.filter(o => !seen[o.ms] && (seen[o.ms] = true));
}

function calendarHtml(p) {
    const s = todayStart();
    const m = new Date(p.month);
    const title = m.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
    const lead = (m.getDay() + 6) % 7;
    const days = new Date(m.getFullYear(), m.getMonth() + 1, 0).getDate();
    let cells = ['M', 'T', 'W', 'T', 'F', 'S', 'S'].map(d => '<span class="cal-dw">' + d + '</span>').join('');
    for (let i = 0; i < lead; i++) cells += '<span></span>';
    for (let d = 1; d <= days; d++) {
        const ms = new Date(m.getFullYear(), m.getMonth(), d).getTime();
        const cls = ['cal-day'];
        if (ms === s) cls.push('today');
        if (ms === p.ms) cls.push('cur');
        cells += '<button class="' + cls.join(' ') + '" data-ms="' + ms + '"' + (ms < s ? ' disabled' : '') + '>' + d + '</button>';
    }
    const atFirst = p.month <= monthStart(s);
    return '<div class="cal"><div class="cal-head"><span>' + esc(title) + '</span><span>' +
        '<button class="cal-nav" data-month="-1" aria-label="Previous month"' + (atFirst ? ' disabled' : '') + '>‹</button>' +
        '<button class="cal-nav" data-month="1" aria-label="Next month">›</button>' +
        '</span></div><div class="cal-grid">' + cells + '</div></div>';
}

function renderPicker() {
    pickerEl.hidden = !st.picker;
    dateBtn.classList.toggle('on', !!st.picker);
    if (!st.picker) { pickerEl.innerHTML = ''; return; }
    const opts = quickDates().map((o, i) =>
        '<button class="opt' + (o.ms === st.picker.ms ? ' sel' : '') + '" data-ms="' + o.ms + '">' +
        '<span>' + esc(o.label) + '</span><span class="hint">' + (i + 1) + ' · ' + esc(fmtShortDay(o.ms)) + '</span></button>'
    ).join('');
    pickerEl.innerHTML = '<div class="picker-opts">' + opts + '</div>' + calendarHtml(st.picker);
}

function fmtShortDay(ms) {
    return new Date(ms).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
}

function setPicker(p) {
    st.picker = p;
    renderPicker();
    renderFoot();
    requestAnimationFrame(reportHeight);
}

// Opens with no day selected; the first arrow press puts the cursor on today.
function togglePicker() {
    setPicker(st.picker ? null : { ms: null, month: monthStart(todayStart()) });
    input.focus();
}

function movePickerDay(days) {
    const ms = st.picker.ms == null ? todayStart() : Math.max(todayStart(), addDays(st.picker.ms, days));
    setPicker({ ms: ms, month: monthStart(ms) });
}

function movePickerMonth(delta) {
    const m = new Date(st.picker.month);
    const month = Math.max(monthStart(todayStart()), new Date(m.getFullYear(), m.getMonth() + delta, 1).getTime());
    setPicker({ ms: st.picker.ms, month: month });
}

/* ======================================================== */
/* OPEN / CLOSE                                             */
/* ======================================================== */

function resetCapture() {
    st.closing = false;
    capture.getAnimations().forEach(a => a.cancel());
    capture.classList.remove('closing');
    capture.style.opacity = '';
    capture.style.transform = '';
    st.menu = null;
    st.sel = null;
    st.calDay = null;
    st.picker = null;
    renderPicker();
    sortMenu.open = false;
    closeSearch();
    st.lastHeight = 0;
    resizeInput();
    render();
    capture.animate(
        [{ opacity: 0, transform: 'translate3d(0, 14px, 0)' }, { opacity: 1, transform: 'translate3d(0, 0, 0)' }],
        { duration: 170, easing: 'cubic-bezier(.22, .61, .36, 1)' }
    );
    setTimeout(() => { input.focus(); renderFoot(); }, 20);
}

function animateClose(done) {
    if (st.closing) return;
    st.closing = true;
    capture.classList.add('closing');
    const animation = capture.animate(
        [{ opacity: 1, transform: 'translate3d(0, 0, 0)' }, { opacity: 0, transform: 'translate3d(0, 18px, 0)' }],
        { duration: 180, easing: 'cubic-bezier(.22, .61, .36, 1)', fill: 'forwards' }
    );
    animation.onfinish = () => { if (done) done(); };
}

function closePanel() {
    animateClose(() => post({ action: 'close' }));
}

/* ======================================================== */
/* EVENTS                                                   */
/* ======================================================== */

document.documentElement.addEventListener('mouseleave', () => {
    // Let an in-flight submission finish before hiding its webview.
    if (!st.closing) post({ action: 'close' });
});

input.addEventListener('input', resizeInput);
input.addEventListener('focus', () => { st.menu = null; renderFoot(); });
input.addEventListener('blur', renderFoot);

document.querySelectorAll('[data-kind]').forEach(button => {
    button.addEventListener('mousedown', e => e.preventDefault());
    button.addEventListener('click', () => {
        if (button.dataset.kind === 'date') togglePicker(); else submit(button.dataset.kind);
    });
});

// Keep focus (and the caret) in the input while using the picker.
pickerEl.addEventListener('mousedown', e => e.preventDefault());
pickerEl.addEventListener('click', e => {
    const nav = e.target.closest('[data-month]');
    if (nav) { movePickerMonth(Number(nav.dataset.month)); return; }
    const day = e.target.closest('[data-ms]');
    if (day) submit('date', Number(day.dataset.ms));
});

$('closeBtn').addEventListener('click', closePanel);
$('dashBtn').addEventListener('click', () => post({ action: 'openPage' }));

/* search */

// Filtering shrinks the list; pin the panel height while searching so the
// window doesn't shrink out from under the mouse (mouseleave closes it).
function openSearch() {
    if (!searchEl.classList.contains('open')) capture.style.minHeight = capture.offsetHeight + 'px';
    searchEl.classList.add('open');
    searchInput.focus();
    searchInput.select();
    renderFoot();
}

function closeSearch() {
    st.query = '';
    searchInput.value = '';
    searchEl.classList.remove('open');
    capture.style.minHeight = '';
}

$('searchBtn').addEventListener('click', openSearch);
searchInput.addEventListener('input', () => {
    st.query = searchInput.value;
    st.menu = null;
    render();
});
searchInput.addEventListener('focus', renderFoot);
searchInput.addEventListener('blur', () => {
    if (!searchInput.value) closeSearch();
    renderFoot();
});

sortMenu.addEventListener('click', e => {
    const option = e.target.closest('[data-sort]');
    if (!option) return;
    st.sort = option.dataset.sort;
    sortMenu.querySelectorAll('[data-sort]').forEach(button => {
        button.setAttribute('aria-checked', String(button === option));
    });
    sortMenu.open = false;
    listEl.focus({ preventScroll: true });
    render();
});
document.addEventListener('click', e => {
    if (!sortMenu.contains(e.target)) sortMenu.open = false;
});

function onClick(e) {
    const target = e.target.closest('[data-act]');
    const row = e.target.closest('.row');
    const menu = e.target.closest('.menu');
    const id = row ? row.dataset.id : (menu ? menu.dataset.for : null);

    if (!target) {
        if (row) select(id);
        return;
    }

    const action = target.dataset.act;

    switch (action) {
        case 'select': select(id); break;
        case 'cycle': cycle(id); break;
        case 'start': case 'pause': case 'done': act(id, action); break;
        case 'tomorrow': act(id, 'move', addDays(todayStart(), 1)); break;
        case 'today': act(id, 'move', todayStart()); break;
        case 'menu': toggleMenu(id); break;
        case 'move': act(id, 'move', Number(target.dataset.ms)); break;
        case 'backlog': act(id, 'backlog'); break;
        case 'undone': undone(id); break;
        case 'link': post({ action: 'openUrl', url: target.dataset.url }); break;
        case 'section':
            st.collapsed[target.dataset.sec] = !st.collapsed[target.dataset.sec];
            render();
            break;
        case 'undo': undo(); break;
        case 'retry': post({ action: 'refresh' }); break;
        case 'list': setView('list'); break;
        case 'dashboard': post({ action: 'openPage' }); break;
        case 'pick': break;
    }
}

listEl.addEventListener('click', onClick);
viewBtn.addEventListener('click', () => setView(st.view === 'calendar' ? 'list' : 'calendar'));
daysEl.addEventListener('click', e => {
    const cell = e.target.closest('[data-day]');
    if (!cell) return;
    st.calDay = Number(cell.dataset.day);
    st.sel = null;
    st.menu = null;
    render();
    listEl.focus({ preventScroll: true });
});
footEl.addEventListener('click', onClick);
toastEl.addEventListener('click', onClick);

// The native date picker opens its own window: don't treat that as "click away".
listEl.addEventListener('focusin', e => {
    if (e.target.matches('input[type=date]')) post({ action: 'pinBlur', on: true });
});
listEl.addEventListener('focusout', e => {
    if (e.target.matches('input[type=date]')) post({ action: 'pinBlur', on: false });
});

listEl.addEventListener('dblclick', e => {
    const row = e.target.closest('.row');
    if (row && !e.target.closest('button')) openTask(row.dataset.id);
});

listEl.addEventListener('change', e => {
    if (!e.target.matches('input[type=date]')) return;
    const value = e.target.value;
    const menu = e.target.closest('.menu');
    if (!value || !menu) return;
    const parts = value.split('-').map(Number);
    act(menu.dataset.for, 'move', new Date(parts[0], parts[1] - 1, parts[2]).getTime());
    listEl.focus({ preventScroll: true });
});

function moveSel(delta) {
    const o = st.order;
    if (!o.length) return;
    let i = o.indexOf(st.sel);
    if (i < 0) i = delta > 0 ? -1 : o.length;
    const next = i + delta;
    if (next < 0) { focusInput(); return; }
    st.sel = o[Math.min(next, o.length - 1)];
    st.menu = null;
    render({ scroll: true });
}

document.addEventListener('keydown', e => {
    if (st.closing) return;

    const k = e.key;
    const lower = k.length === 1 ? k.toLowerCase() : k;
    const inInput = e.target === input;
    const inDate = e.target.matches && e.target.matches('input[type=date]');
    const meta = e.metaKey;

    if (meta && lower === 'f') { e.preventDefault(); openSearch(); return; }

    if (e.target === searchInput) {
        if (k === 'Escape') {
            e.preventDefault();
            closeSearch();
            render();
            listEl.focus({ preventScroll: true });
            return;
        }
        if ((k === 'ArrowDown' || (k === 'Enter' && !e.isComposing)) && st.order.length) {
            e.preventDefault();
            listEl.focus({ preventScroll: true });
            st.sel = st.order[0];
            render({ scroll: true });
        }
        return;
    }

    if (k === 'Escape') {
        e.preventDefault();
        if (sortMenu.open) {
            sortMenu.open = false;
            sortMenu.querySelector('summary').focus({ preventScroll: true });
            return;
        }
        if (st.picker) {
            setPicker(null);
            return;
        }
        if (st.menu != null) {
            st.menu = null;
            listEl.focus({ preventScroll: true });
            render();
            return;
        }
        if (st.query) {
            closeSearch();
            render();
            return;
        }
        closePanel();
        return;
    }

    if (meta && lower === 'r') { e.preventDefault(); post({ action: 'refresh' }); return; }

    if (meta && !e.shiftKey && lower === 'z' && !(inInput && input.value)) {
        e.preventDefault();
        undo();
        return;
    }

    if (inInput) {
        if (meta && lower === 'd') { e.preventDefault(); togglePicker(); return; }
        if (st.picker && !meta && !e.isComposing) {
            const quick = quickDates();
            if (/^[1-9]$/.test(k) && Number(k) <= quick.length) { e.preventDefault(); submit('date', quick[Number(k) - 1].ms); return; }
            const step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }[k];
            if (step) { e.preventDefault(); movePickerDay(step); return; }
            if (k === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                if (st.picker.ms != null) submit('date', st.picker.ms);
                return;
            }
        }
        if (meta && lower === 'b') { e.preventDefault(); submit('backlog'); return; }
        if (meta && lower === 'p') { e.preventDefault(); submit('page'); return; }
        if (meta && lower === 't') { e.preventDefault(); submit(e.shiftKey ? 'tomorrow' : 'today'); return; }
        if (k === 'Enter' && !e.shiftKey && !meta && !e.isComposing) { e.preventDefault(); submit('note'); return; }
        const atEnd = input.selectionStart === input.value.length && input.selectionEnd === input.value.length;
        if ((k === 'ArrowDown' && atEnd) || (k === 'Tab' && !e.shiftKey)) {
            if (st.order.length) {
                e.preventDefault();
                input.blur();
                listEl.focus({ preventScroll: true });
                st.sel = st.order[0];
                render({ scroll: true });
            }
        }
        return;
    }

    if (inDate || sortMenu.contains(e.target)) return;
    if (meta || e.ctrlKey || e.altKey) return;

    if (st.menu != null && /^[1-9]$/.test(k)) {
        e.preventDefault();
        pickMenu(Number(k) - 1);
        return;
    }

    if (lower === 'c') { e.preventDefault(); setView(st.view === 'calendar' ? 'list' : 'calendar'); return; }
    if (st.view === 'calendar' && (k === 'ArrowLeft' || k === 'ArrowRight')) {
        e.preventDefault();
        moveCalDay((k === 'ArrowLeft' ? -1 : 1) * (e.shiftKey ? 7 : 1));
        return;
    }

    const sel = st.sel;
    const sec = sel != null ? st.secOf[sel] : null;

    switch (lower) {
        case 'ArrowDown': case 'j': e.preventDefault(); moveSel(1); break;
        case 'ArrowUp': case 'k': e.preventDefault(); moveSel(-1); break;
        case ' ': case 'x':
            e.preventDefault();
            if (sel == null) break;
            if (sec === 'done') undone(sel); else act(sel, 'done');
            break;
        case 's':
            e.preventDefault();
            if (sel == null || sec === 'done') break;
            act(sel, sec === 'doing' ? 'pause' : 'start');
            break;
        case 't':
            e.preventDefault();
            if (sel == null || sec === 'done') break;
            act(sel, 'move', sec === 'tomorrow' ? todayStart() : addDays(todayStart(), 1));
            break;
        case 'd':
            e.preventDefault();
            if (sel != null && sec !== 'done') toggleMenu(sel);
            break;
        case 'b':
            e.preventDefault();
            if (sel != null && sec !== 'done') act(sel, 'backlog');
            break;
        case 'Enter': case 'o':
            e.preventDefault();
            if (sel != null) openTask(sel);
            break;
        case '/': case 'n': case 'Tab':
            e.preventDefault();
            focusInput();
            break;
    }
});

/* ======================================================== */
/* API FOR LUA                                              */
/* ======================================================== */

window.app = {
    setData(raw, meta) {
        const res = raw && raw.data ? raw.data.result : null;
        const rows = Array.isArray(res) ? res : [];
        st.tasks = rows
            .map(r => (Array.isArray(r) ? r[0] : r))
            .filter(p => p && typeof p === 'object')
            .map(normTask)
            .filter(t => t.id != null);
        meta = meta || {};
        if (meta.start) st.bounds = { start: meta.start, end: meta.end, end2: meta.end2, until: meta.until || addDays(weekStart(meta.start), 14) };
        st.done = (Array.isArray(meta.done) ? meta.done : []).map(d => ({
            id: d.id, uuid: d.uuid || '', title: d.title || '', links: [], modifiedAt: num(d.modifiedAt)
        }));
        st.temps = [];
        st.loaded = true;
        st.error = null;
        render();
    },
    setDashboard(info) {
        const page = (info && info.page) || '';
        const btn = $('dashBtn');
        btn.hidden = !page;
        btn.nextElementSibling.hidden = !page;
        btn.textContent = page + ' ↗';
        btn.title = 'Open ' + page + ' in Logseq';
    },
    setLoading(on) {
        st.loading = !!on;
        dotEl.className = 'dot' + (st.loading ? ' loading' : '') + (st.error ? ' error' : '');
    },
    setError(info) {
        st.error = (info && info.message) || 'unknown error';
        st.loading = false;
        render();
    },
    result(info) {
        if (!info || info.ok) return;
        st.temps = st.temps.filter(t => t.req !== info.req);
        render();
        toast('Logseq: ' + (info.message || 'error'), { error: true, retry: true });
    },
    reset: resetCapture
};

window.logseqCaptureReset = resetCapture;

document.addEventListener('DOMContentLoaded', () => {
    resizeInput();
    render();
    post({ action: 'ready' });
});

})();
</script>
</body>
</html>
]==]


-- ============================================================
-- PEEK HTML
-- ============================================================

local peekHtml = [==[
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="dark light">
<style>
:root {
    --panel: rgba(28,28,31,.97); --border: rgba(255,255,255,.14);
    --text: rgba(255,255,255,.92); --muted: rgba(255,255,255,.5);
    --btn: rgba(255,255,255,.06); --btn-border: rgba(255,255,255,.10);
    --orange: #f5a524; --blue: #0a84ff;
}
@media (prefers-color-scheme: light) {
    :root {
        --panel: rgba(248,248,250,.97); --border: rgba(0,0,0,.10);
        --text: rgba(0,0,0,.87); --muted: rgba(0,0,0,.5);
        --btn: rgba(0,0,0,.045); --btn-border: rgba(0,0,0,.08);
        --orange: #c77700;
    }
}
* { box-sizing: border-box; }
html, body {
    margin: 0; width: 100%; height: 100%; overflow: hidden;
    background: transparent !important;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    -webkit-font-smoothing: antialiased; user-select: none; -webkit-user-select: none;
}
body { padding: 8px; }
.pill {
    height: 100%; display: flex; flex-direction: column; justify-content: center;
    padding: 4px 8px 4px 12px; border-radius: 14px;
    border: 1px solid var(--border); background: var(--panel);
    box-shadow: 0 2px 6px rgba(0,0,0,.28);
    color: var(--text);
}
.row {
    appearance: none; border: 0; background: none; padding: 0; margin: 0;
    height: 28px; flex: 0 0 auto; width: 100%;
    display: flex; align-items: center; gap: 8px;
    text-align: left; cursor: default; color: inherit; font: inherit;
}
.ring { flex: 0 0 auto; color: var(--orange); display: flex; }
.ttl { flex: 1; min-width: 0; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.elapsed {
    flex: 0 0 auto; min-width: 56px; text-align: right;
    font-size: 13px; font-weight: 450; font-variant-numeric: tabular-nums;
    color: var(--muted); opacity: .8;
}
</style>
</head>
<body>
<div class="pill" id="pill"></div>
<script>
(function () {
'use strict';
let tasks = [];
let hoverAnimation = null;
let elapsedTimer = null;
const pill = document.getElementById('pill');
const RING = '<svg width="14" height="14" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="7.25" stroke="currentColor" stroke-width="1.5"/><path d="M9 1.75a7.25 7.25 0 0 1 0 14.5z" fill="currentColor"/></svg>';
function formatElapsed(startedAt) {
    if (!Number.isFinite(startedAt)) return '';
    const seconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor(seconds / 60) % 60;
    const pad = n => String(n).padStart(2, '0');
    return (hours ? hours + ':' : '') + pad(minutes) + ':' + pad(seconds % 60);
}
function renderElapsed() {
    pill.querySelectorAll('.elapsed').forEach((el, i) => {
        el.textContent = formatElapsed(tasks[i] && tasks[i].startedAt);
    });
}
function post(m) {
    try { window.webkit.messageHandlers.logseqPeek.postMessage(m); } catch (e) { console.error(e); }
}
function cleanTitle(raw, refs) {
    const map = {};
    (refs || []).forEach(r => { if (r.uuid) map[String(r.uuid).toLowerCase()] = r.title; });
    let t = String(raw || '')
        .replace(/\[\[([0-9a-f-]{36})\]\]/gi, (m, u) => map[u.toLowerCase()] || '…')
        .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '$1')
        .replace(/\[\[([^\]]+)\]\]/g, '$1');
    let host = '';
    t = t.replace(/https?:\/\/[^\s<>()\[\]]+/g, u => { if (!host) { try { host = new URL(u).hostname.replace(/^www\./, ''); } catch (e) {} } return ' '; });
    t = t.replace(/\s+/g, ' ').replace(/^[\s\-–—:·|]+|[\s\-–—:·|]+$/g, '').trim();
    return t || host || 'Untitled';
}
window.peek = {
    setHovered(on) {
        if (hoverAnimation) hoverAnimation.cancel();
        hoverAnimation = pill.animate(
            on
                ? [{ transform: 'translateX(0)' }, { transform: 'translateX(110%)' }]
                : [{ transform: 'translateX(110%)' }, { transform: 'translateX(0)' }],
            { duration: 150, easing: 'ease-out', fill: 'forwards' }
        );
        if (on) hoverAnimation.onfinish = () => post({ action: 'hoverHidden' });
    },
    set(list) {
        tasks = Array.isArray(list) ? list.slice(0, 5) : [];
        pill.textContent = '';
        tasks.forEach(t => {
            const row = document.createElement('button');
            row.className = 'row';
            row.dataset.act = 'expand';
            row.title = 'Open panel';
            row.innerHTML = '<span class="ring">' + RING + '</span>' +
                '<span class="ttl"></span>' +
                '<span class="elapsed" title="Elapsed since starting in this panel"></span>';
            row.querySelector('.ttl').textContent = cleanTitle(t.title, t.refs);
            pill.appendChild(row);
        });
        if (elapsedTimer) clearInterval(elapsedTimer);
        elapsedTimer = null;
        renderElapsed();
        if (tasks.some(t => Number.isFinite(t.startedAt))) elapsedTimer = setInterval(renderElapsed, 1000);
    }
};
document.addEventListener('click', e => {
    const b = e.target.closest('[data-act]');
    if (!b || !tasks.length) return;
    const act = b.dataset.act;
    if (act === 'expand') post({ action: 'expand' });
});
document.addEventListener('DOMContentLoaded', () => post({ action: 'ready' }));
})();
</script>
</body>
</html>
]==]


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

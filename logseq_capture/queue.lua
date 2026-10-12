-- ============================================================
-- QUEUE: writes and refreshes run strictly one after another.
-- A refresh result is applied only if no write is waiting,
-- so optimistic UI never gets overwritten by stale data.
-- ============================================================

local S = require("logseq_capture.state")
local util = require("logseq_capture.util")
local cli = require("logseq_capture.cli")
local bridge = require("logseq_capture.bridge")
local filter = require("logseq_capture.filter")

local log = util.log
local fmtInt = util.fmtInt
local dayStartMs = util.dayStartMs
local jsPanel = bridge.jsPanel

local M = {}

-- Called after a refresh stored fresh data in S.cache; set by init.lua.
M.onData = function() end


local pump


local function hasWrites()
    for _, job in ipairs(S.queue) do
        if job.kind == "write" then
            return true
        end
    end

    return false
end


local function enqueue(job)
    S.queue[#S.queue + 1] = job
    pump()
end


function M.requestRefresh()
    S.refreshWanted = true
    pump()
end


-- ?until of the tasks query: end of the calendar grid,
-- Monday of this week + 14 days (os.date wday: 1 = Sunday).
function M.untilMs()
    return dayStartMs(14 - (os.date("*t").wday + 5) % 7)
end


-- CLI args of the tasks query (saved filter unless one is given).
function M.tasksQueryArgs(query, untilMs)
    return {
        "query",
        "--query", query or filter.current(),
        "--inputs", "[" .. fmtInt(untilMs) .. "]",
    }
end


local function makeRefreshJob()
    local start = dayStartMs(0)
    local finish = dayStartMs(1)
    local finish2 = dayStartMs(2)
    local untilMs = M.untilMs()

    return {
        kind = "refresh",
        args = M.tasksQueryArgs(nil, untilMs),
        cb = function(ok, raw, decoded, message)
            jsPanel("app.setLoading(false)")

            if hasWrites() then
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

            M.onData()
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

    cli.start(job.args, function(...)
        S.busy = false

        local okCb, err = pcall(job.cb, ...)

        if not okCb then
            log("job callback error:", err)
        end

        -- let the UI breathe between commands
        hs.timer.doAfter(0, pump)
    end)
end


-- A query that only reads: no refresh afterwards.
function M.enqueueRead(args, onDone)
    enqueue({
        kind = "read",
        args = args,
        cb = onDone,
    })
end


function M.enqueueWrite(args, onDone)
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


return M

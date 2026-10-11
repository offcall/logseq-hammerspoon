-- ============================================================
-- QUEUE: writes and refreshes run strictly one after another.
-- A refresh result is applied only if no write is waiting,
-- so optimistic UI never gets overwritten by stale data.
-- ============================================================

local S = require("logseq_capture.state")
local util = require("logseq_capture.util")
local cli = require("logseq_capture.cli")
local bridge = require("logseq_capture.bridge")

local log = util.log
local fmtInt = util.fmtInt
local dayStartMs = util.dayStartMs
local jsPanel = bridge.jsPanel

local M = {}

-- Called after a refresh stored fresh data in S.cache; set by init.lua.
M.onData = function() end


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


local pump


local function enqueue(job)
    S.queue[#S.queue + 1] = job
    pump()
end


function M.requestRefresh()
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

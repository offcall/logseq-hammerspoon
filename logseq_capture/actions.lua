-- ============================================================
-- ACTIONS FROM THE UI: task updates, captures, opening Logseq
-- ============================================================

local config = require("logseq_capture.config")
local S = require("logseq_capture.state")
local util = require("logseq_capture.util")
local bridge = require("logseq_capture.bridge")
local queue = require("logseq_capture.queue")
local done = require("logseq_capture.done")

local GRAPH = config.GRAPH
local STATUS = config.STATUS
local VALID_STATUS = config.VALID_STATUS
local TASK_STARTS_KEY = config.TASK_STARTS_KEY
local log = util.log
local trim = util.trim
local urlEncode = util.urlEncode
local fmtInt = util.fmtInt
local dayStartMs = util.dayStartMs
local notifyError = bridge.notifyError
local enqueueWrite = queue.enqueueWrite

local M = {}


function M.openLogseqUrl(query)
    local url = "logseq://graph/" .. urlEncode(GRAPH) .. "?" .. query
    log("OPEN:", url)
    hs.urlevent.openURL(url)
end


function M.handleUpdate(body)
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
                done.mark(body.id, body.uuid, body.title)
            elseif status ~= "" then
                done.unmark(body.id)
            end
        else
            notifyError(body.req, message)
        end
    end)
end


function M.handleCapture(body)
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
                    M.openLogseqUrl("page=" .. urlEncode(text))
                else
                    notifyError(body.req, message)
                end
            end
        )
    end
end


return M

-- ============================================================
-- DONE-TODAY LIST (done tasks leave the queries, keep them visible)
-- ============================================================

local S = require("logseq_capture.state")
local util = require("logseq_capture.util")

local fmtInt = util.fmtInt

local DONE_KEY = "logseqCapture.doneToday"

local M = {}


local function todayKey()
    return os.date("%Y-%m-%d")
end


local function saveDone()
    hs.settings.set(DONE_KEY, S.done)
end


function M.roll()
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


function M.unmark(id)
    M.roll()

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


function M.mark(id, uuid, title)
    M.unmark(id)

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


return M

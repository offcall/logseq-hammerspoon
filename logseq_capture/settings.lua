-- ============================================================
-- SETTINGS SCREEN: messages of the panel's settings view
-- (which tasks the panel shows, see filter.lua).
-- ============================================================

local config = require("logseq_capture.config")
local filter = require("logseq_capture.filter")
local queue = require("logseq_capture.queue")
local bridge = require("logseq_capture.bridge")
local util = require("logseq_capture.util")

local jsPanel = bridge.jsPanel

local M = {}

local SAMPLE_SIZE = 5


local function send(fn, data)
    jsPanel("app." .. fn .. "(" .. hs.json.encode(data) .. ")")
end


local function resultRows(decoded)
    local data = decoded and decoded.data
    local rows = type(data) == "table" and data.result or nil

    return type(rows) == "table" and rows or {}
end


local function loadStatuses()
    queue.enqueueRead({ "query", "--query", filter.STATUSES_QUERY }, function(ok, _, decoded, message)
        if not ok then
            send("settingsStatuses", { ok = false, message = message or "query failed" })
            return
        end

        local items = {}

        for _, row in ipairs(resultRows(decoded)) do
            local ident = type(row) == "table" and tostring(row[1] or ""):gsub("^:", "") or ""

            if filter.isStatusIdent(ident) then
                items[#items + 1] = {
                    ident = ident,
                    title = tostring(row[2] or ident),
                    closed = filter.CLOSED[ident] == true,
                }
            end
        end

        send("settingsStatuses", { ok = true, items = items })
    end)
end


-- The panel reads (pull ?task [...]) maps with :db/id.
local function checkShape(rows)
    local sample = {}

    for _, row in ipairs(rows) do
        local pull = row

        if type(row) == "table" and row[1] ~= nil then
            pull = row[1]
        end

        if type(pull) ~= "table" or pull["db/id"] == nil then
            return nil, "Wrong result shape: rows must be (pull ?task [...]) maps with :db/id"
        end

        if #sample < SAMPLE_SIZE then
            sample[#sample + 1] = { title = pull["block/title"], refs = pull["block/refs"] }
        end
    end

    return sample
end


local function test(body)
    local req = tonumber(body.req) or 0
    local query = util.trim(filter.build(filter.normalize(body.filter)))

    if query == "" then
        send("settingsTested", { req = req, ok = false, message = "The query is empty" })
        return
    end

    local started = hs.timer.secondsSinceEpoch()

    queue.enqueueRead(queue.tasksQueryArgs(query, queue.untilMs()), function(ok, _, decoded, message)
        local seconds = hs.timer.secondsSinceEpoch() - started

        if not ok then
            send("settingsTested", { req = req, ok = false, message = message or "query failed" })
            return
        end

        local rows = resultRows(decoded)
        local sample, shapeError = checkShape(rows)

        send("settingsTested", {
            req = req,
            ok = sample ~= nil,
            message = shapeError,
            count = #rows,
            sample = sample or {},
            seconds = seconds,
        })
    end)
end


-- Handles a settings* message from the panel; false if not one.
function M.handle(body)
    local action = body.action

    if action == "settingsOpen" then
        send("settingsLoaded", { filter = filter.load(), graph = config.GRAPH })
        loadStatuses()

    elseif action == "settingsBuild" then
        send("settingsBuilt", { query = filter.buildFromStatuses(filter.normalize(body.filter)) })

    elseif action == "settingsTest" then
        test(body)

    elseif action == "settingsSave" then
        filter.save(body.filter)
        send("settingsSaved", {})
        queue.requestRefresh()

    elseif action == "settingsReset" then
        filter.reset()
        send("settingsLoaded", { filter = filter.load(), graph = config.GRAPH, reset = true })
        queue.requestRefresh()

    else
        return false
    end

    return true
end


return M

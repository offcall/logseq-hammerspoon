-- ============================================================
-- TASK FILTER: which tasks the refresh query fetches.
-- Set on the panel's settings screen and stored per graph in
-- hs.settings; without a saved filter DEFAULT is used.
--
-- mode "statuses": open statuses + "a #Task without a status
-- counts as todo"; Doing tasks always, others only when dated.
-- mode "custom": the user's own datalog query with the same
-- pull pattern and `:in $ ?until` as TEMPLATE.
-- ============================================================

local config = require("logseq_capture.config")

local M = {}

local SETTINGS_KEY = "logseqCapture.taskFilter." .. config.GRAPH

local STATUS_PREFIX = "logseq.property/status."

-- Done tasks leave the query ("Done today" is kept locally).
M.CLOSED = {
    [STATUS_PREFIX .. "done"] = true,
    [STATUS_PREFIX .. "canceled"] = true,
}

M.DEFAULT = {
    mode = "statuses",
    statuses = {
        STATUS_PREFIX .. "todo",
        STATUS_PREFIX .. "backlog",
        STATUS_PREFIX .. "doing",
        STATUS_PREFIX .. "in-review",
    },
    noStatusAsTodo = true,
    query = "",
}

-- Every value of the Status property: [ident title] rows.
M.STATUSES_QUERY = [=[
[:find ?ident ?title
 :where
 [?p :db/ident :logseq.property/status]
 [?v :block/closed-value-property ?p]
 [?v :db/ident ?ident]
 [?v :block/title ?title]]
]=]

-- Every dated task before ?until + every Doing task, in ONE query.
-- ?until = end of the calendar grid: Monday of the week after next
-- (local time, epoch ms). The list mode filters to tomorrow in JS.
local TEMPLATE = [=[
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
     [(contains? #{STATUS_IDENTS} ?status-id)])
   NO_STATUS_CLAUSE)
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

local NO_STATUS_CLAUSE = [=[;; a #Task without a status counts as todo
   (and
     [?task-class :db/ident :logseq.class/Task]
     [?task :block/tags ?task-class]
     (not [?task :logseq.property/status]))]=]


-- Idents are inserted into the query text: allow only plain names.
function M.isStatusIdent(value)
    return type(value) == "string" and value:match("^[%w%._%-]+/[%w%._%-]+$") ~= nil
end


-- Any table (saved or from JS) → a complete, safe filter.
function M.normalize(raw)
    raw = type(raw) == "table" and raw or {}

    local statuses = {}
    local list = type(raw.statuses) == "table" and raw.statuses or M.DEFAULT.statuses

    for _, ident in ipairs(list) do
        ident = tostring(ident):gsub("^:", "")

        if M.isStatusIdent(ident) and not M.CLOSED[ident] then
            statuses[#statuses + 1] = ident
        end
    end

    local noStatusAsTodo = raw.noStatusAsTodo
    if type(noStatusAsTodo) ~= "boolean" then
        noStatusAsTodo = M.DEFAULT.noStatusAsTodo
    end

    return {
        mode = raw.mode == "custom" and "custom" or "statuses",
        statuses = statuses,
        noStatusAsTodo = noStatusAsTodo,
        query = type(raw.query) == "string" and raw.query or "",
    }
end


function M.buildFromStatuses(filter)
    local idents = {}

    for _, ident in ipairs(filter.statuses) do
        idents[#idents + 1] = ":" .. ident
    end

    -- Function replacements: no % escaping in the inserted text.
    return (TEMPLATE
        :gsub("STATUS_IDENTS", function() return table.concat(idents, " ") end)
        :gsub("NO_STATUS_CLAUSE", function() return filter.noStatusAsTodo and NO_STATUS_CLAUSE or "" end))
end


function M.build(filter)
    if filter.mode == "custom" then
        return filter.query
    end

    return M.buildFromStatuses(filter)
end


function M.load()
    return M.normalize(hs.settings.get(SETTINGS_KEY) or M.DEFAULT)
end


function M.save(filter)
    hs.settings.set(SETTINGS_KEY, M.normalize(filter))
end


function M.reset()
    hs.settings.clear(SETTINGS_KEY)
end


-- Query of the saved filter, used by every refresh.
function M.current()
    return M.build(M.load())
end


return M

-- ============================================================
-- TASK DATA: rows of the last refresh (S.cache)
-- ============================================================

local S = require("logseq_capture.state")

local M = {}


function M.pulls()
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


function M.identOf(value)
    if type(value) == "table" then
        value = value["db/ident"]
    end

    if type(value) ~= "string" then
        return ""
    end

    return value:gsub("^:", ""):match("([^%.]+)$") or ""
end


return M

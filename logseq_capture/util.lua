-- ============================================================
-- HELPERS
-- ============================================================

local M = {}


function M.log(...)
    print("[Logseq Panel]", ...)
end


function M.trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end


function M.containsPoint(frame, point)
    return point.x >= frame.x and point.x < frame.x + frame.w
        and point.y >= frame.y and point.y < frame.y + frame.h
end


function M.shellQuote(value)
    return "'" .. (tostring(value):gsub("'", "'\"'\"'")) .. "'"
end


function M.urlEncode(value)
    return (
        tostring(value):gsub(
            "([^%w%-_%.~])",
            function(c)
                return string.format("%%%02X", string.byte(c))
            end
        )
    )
end


function M.fmtInt(value)
    return string.format("%.0f", tonumber(value) or 0)
end


-- Local midnight of today + offset days, epoch ms.
function M.dayStartMs(offsetDays)
    local t = os.date("*t")

    return os.time({
        year = t.year,
        month = t.month,
        day = t.day + (offsetDays or 0),
        hour = 0, min = 0, sec = 0,
    }) * 1000
end


return M

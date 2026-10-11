-- ============================================================
-- WEB ASSETS
-- Webviews get one HTML string: an HTML file from web/ with its
-- <link rel="stylesheet" href="x.css"> and <script src="x.js"></script>
-- tags replaced by the file contents.
-- ============================================================

local M = {}

local WEB_DIR =
    (debug.getinfo(1, "S").source:match("^@(.*/)") or (hs.configdir .. "/logseq_capture/"))
    .. "web/"


local function read(name)
    local file = assert(io.open(WEB_DIR .. name, "r"))
    local content = file:read("*a")
    file:close()

    return content
end


function M.page(name)
    local html = read(name)

    html = html:gsub('<link rel="stylesheet" href="([%w%._%-]+)">', function(file)
        return "<style>\n" .. read(file) .. "</style>"
    end)

    html = html:gsub('<script src="([%w%._%-]+)"></script>', function(file)
        return "<script>\n" .. read(file) .. "</script>"
    end)

    return html
end


return M

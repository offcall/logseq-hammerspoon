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

local M = {}

M.LOGSEQ = setting("logseq", os.getenv("HOME") .. "/.local/bin/logseq")
M.GRAPH = setting("graph", "Personal")
M.DASHBOARD_PAGE = setting("dashboardPage", "Dashboard")

M.WIDTH = 460
M.MIN_HEIGHT = 150
M.MAX_HEIGHT = 720
M.SCREEN_MARGIN = 18

M.CORNER_SIZE = 14
M.REARM_DISTANCE = 80

M.CLI_TIMEOUT = 45           -- seconds; first call may start db-worker
M.REFRESH_INTERVAL = 300     -- seconds; background refresh (for the peek)

M.SHOW_PEEK = true
M.PEEK_WIDTH = 380
M.PEEK_ROW_HEIGHT = 28       -- one Doing task in the peek
M.PEEK_MAX_ROWS = 5

-- Optional global hotkey to toggle the panel, e.g. { {"cmd", "alt"}, "L" }
M.OPEN_HOTKEY = setting("openHotkey", nil)

-- Status values as the CLI accepts them (it normalizes case / prefixes).
M.STATUS = {
    todo = "todo",
    doing = "doing",
    done = "done",
    backlog = "backlog",
}

M.VALID_STATUS = {
    todo = true, doing = true, done = true,
    backlog = true, ["in-review"] = true, canceled = true,
}

M.TASK_STARTS_KEY = "logseqCapture.taskStarts." .. M.GRAPH

M.USER_SHELL = os.getenv("SHELL") or "/bin/zsh"


return M

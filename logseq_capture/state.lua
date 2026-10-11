-- ============================================================
-- SHARED STATE: _G.logseqCapture
-- Requiring this module first cleans up the old instance after a
-- reload (also handles the previous version of this script).
-- Every new long-lived object (timer, webview, hotkey, watcher)
-- must be added to this cleanup.
-- ============================================================

local config = require("logseq_capture.config")

if _G.logseqCapture then
    local old = _G.logseqCapture

    for _, key in ipairs({ "cornerTimer", "refreshTimer" }) do
        if old[key] then
            pcall(function() old[key]:stop() end)
        end
    end

    if old.hotkey then
        pcall(function() old.hotkey:delete() end)
    end

    if old.currentTask then
        pcall(function()
            if old.currentTask:isRunning() then
                old.currentTask:terminate()
            end
        end)
    end

    for _, key in ipairs({ "popup", "peek" }) do
        if old[key] then
            pcall(function() old[key]:hide() end)
            pcall(function() old[key]:delete() end)
        end
    end
end


_G.logseqCapture = {
    popup = nil,
    usercontent = nil,
    peek = nil,
    peekContent = nil,

    cornerTimer = nil,
    refreshTimer = nil,
    hotkey = nil,

    ready = false,
    peekReady = false,
    pendingShow = false,
    visible = false,
    peekVisible = false,
    peekHovered = false,
    lastHeight = config.MIN_HEIGHT,

    cornerArmed = true,
    canBlurClose = false,
    blurPinned = false,

    env = nil,
    queue = {},
    busy = false,
    refreshWanted = false,
    currentTask = nil,

    cache = nil,
    done = nil,
}

local S = _G.logseqCapture
S.taskStarts = hs.settings.get(config.TASK_STARTS_KEY)
if type(S.taskStarts) ~= "table" then S.taskStarts = {} end


return S

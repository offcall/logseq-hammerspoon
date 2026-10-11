-- ============================================================
-- HOT CORNER: bottom-right corner opens the panel; also drives
-- the peek hover.
-- ============================================================

local config = require("logseq_capture.config")
local S = require("logseq_capture.state")
local peek = require("logseq_capture.peek")
local panel = require("logseq_capture.panel")

local CORNER_SIZE = config.CORNER_SIZE
local REARM_DISTANCE = config.REARM_DISTANCE

local M = {}


function M.start()
    S.cornerTimer = hs.timer.doEvery(0.10, function()
        local position = hs.mouse.absolutePosition()
        peek.updateHover(position)
        local screen = hs.mouse.getCurrentScreen()

        if not screen then
            return
        end

        local frame = screen:fullFrame()

        local right = (frame.x + frame.w) - position.x
        local bottom = (frame.y + frame.h) - position.y

        -- Leave corner → allow next trigger.
        if right > REARM_DISTANCE or bottom > REARM_DISTANCE then
            S.cornerArmed = true
        end

        -- Hit bottom-right corner.
        if S.cornerArmed
            and not S.visible
            and right >= 0
            and bottom >= 0
            and right <= CORNER_SIZE
            and bottom <= CORNER_SIZE
        then
            S.cornerArmed = false
            panel.show()
        end
    end)
end


return M

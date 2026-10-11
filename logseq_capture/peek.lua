-- ============================================================
-- PEEK: pill with the current Doing tasks (web/peek.*)
-- ============================================================

local config = require("logseq_capture.config")
local S = require("logseq_capture.state")
local util = require("logseq_capture.util")
local bridge = require("logseq_capture.bridge")
local tasks = require("logseq_capture.tasks")
local assets = require("logseq_capture.assets")

local SHOW_PEEK = config.SHOW_PEEK
local PEEK_WIDTH = config.PEEK_WIDTH
local PEEK_ROW_HEIGHT = config.PEEK_ROW_HEIGHT
local PEEK_MAX_ROWS = config.PEEK_MAX_ROWS
local SCREEN_MARGIN = config.SCREEN_MARGIN
local fmtInt = util.fmtInt
local containsPoint = util.containsPoint
local jsPeek = bridge.jsPeek
local pulls = tasks.pulls
local identOf = tasks.identOf

local M = {}


local function peekHeight(rows)
    -- 8px transparent padding on each side + 4px pill padding on each side.
    return math.min(rows, PEEK_MAX_ROWS) * PEEK_ROW_HEIGHT + 24
end


local function positionPeek(rows)
    if not S.peek then
        return
    end

    local screen = hs.screen.mainScreen()

    if not screen then
        return
    end

    local frame = screen:frame()
    local height = peekHeight(rows)

    S.peek:frame({
        x = frame.x + frame.w - PEEK_WIDTH - SCREEN_MARGIN + 8,
        y = frame.y + frame.h - height - SCREEN_MARGIN + 8,
        w = PEEK_WIDTH,
        h = height,
    })
end


function M.hide()
    if S.peekHovered then
        S.peekHovered = false
        jsPeek("peek.setHovered(false)")
    end

    if S.peek and S.peekVisible then
        S.peek:hide()
        S.peekVisible = false
    end
end


function M.updateHover(position)
    if not S.peek or not (S.peekVisible or S.peekHovered) then
        return
    end

    -- Keep using the original frame even while the webview is hidden.
    local hovered = containsPoint(S.peek:frame(), position)

    if hovered ~= S.peekHovered then
        S.peekHovered = hovered
        jsPeek("peek.setHovered(" .. tostring(hovered) .. ")")

        if not hovered then
            M.update()
        end
    end
end


function M.update()
    if not SHOW_PEEK or not S.peek or not S.peekReady then
        return
    end

    if S.visible or not S.cache then
        M.hide()
        return
    end

    local list = {}

    for _, pull in ipairs(pulls()) do
        if identOf(pull["logseq.property/status"]) == "doing" then
            local refs = {}

            if type(pull["block/refs"]) == "table" then
                for _, ref in ipairs(pull["block/refs"]) do
                    if type(ref) == "table" and ref["block/uuid"] and ref["block/title"] then
                        refs[#refs + 1] = {
                            uuid = tostring(ref["block/uuid"]),
                            title = tostring(ref["block/title"]),
                        }
                    end
                end
            end

            list[#list + 1] = {
                id = pull["db/id"],
                title = tostring(pull["block/title"] or ""),
                refs = refs,
                startedAt = S.taskStarts[fmtInt(pull["db/id"])],
            }
        end
    end

    if #list == 0 then
        M.hide()
        return
    end

    jsPeek("peek.set(" .. hs.json.encode(list) .. ")")

    positionPeek(#list)

    if S.peekHovered then
        return
    end

    if not S.peekVisible then
        S.peek:show()
        S.peekVisible = true
    end
end


-- onExpand: called when the pill is clicked (opens the panel).
function M.create(onExpand)
    if not SHOW_PEEK then
        return
    end

    S.peekContent = hs.webview.usercontent.new("logseqPeek")

    S.peekContent:setCallback(function(message)
        local body = message.body

        if type(body) ~= "table" then
            return
        end

        if body.action == "ready" then
            S.peekReady = true
            M.update()
        elseif body.action == "expand" then
            onExpand()
        elseif body.action == "hoverHidden" and S.peekHovered then
            -- Hiding the native window lets clicks reach the app underneath.
            S.peek:hide()
            S.peekVisible = false
        end
    end)

    S.peek = hs.webview.new(
        { x = 0, y = 0, w = PEEK_WIDTH, h = peekHeight(1) },
        { javaScriptEnabled = true },
        S.peekContent
    )

    -- "nonactivating" keeps the peek from stealing focus.
    local okStyle = pcall(function()
        S.peek:windowStyle({ "borderless", "nonactivating" })
    end)

    if not okStyle then
        S.peek:windowStyle({ "borderless" })
    end

    S.peek
        :transparent(true)
        :shadow(false)
        :closeOnEscape(false)
        :level(hs.drawing.windowLevels.floating)

    S.peek:html(assets.page("peek.html"))
end


return M

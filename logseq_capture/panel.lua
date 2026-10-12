-- ============================================================
-- PANEL: capture + task list webview (web/panel.*)
-- ============================================================

local config = require("logseq_capture.config")
local S = require("logseq_capture.state")
local util = require("logseq_capture.util")
local bridge = require("logseq_capture.bridge")
local tasks = require("logseq_capture.tasks")
local done = require("logseq_capture.done")
local queue = require("logseq_capture.queue")
local actions = require("logseq_capture.actions")
local peek = require("logseq_capture.peek")
local assets = require("logseq_capture.assets")
local settings = require("logseq_capture.settings")

local DASHBOARD_PAGE = config.DASHBOARD_PAGE
local WIDTH = config.WIDTH
local MIN_HEIGHT = config.MIN_HEIGHT
local MAX_HEIGHT = config.MAX_HEIGHT
local SCREEN_MARGIN = config.SCREEN_MARGIN
local TASK_STARTS_KEY = config.TASK_STARTS_KEY
local log = util.log
local urlEncode = util.urlEncode
local fmtInt = util.fmtInt
local jsPanel = bridge.jsPanel

local M = {}


-- ============================================================
-- DATA → WEBVIEWS
-- ============================================================

function M.applyData()
    if not S.cache then
        return
    end

    done.roll()

    local active = {}
    for _, pull in ipairs(tasks.pulls()) do
        if tasks.identOf(pull["logseq.property/status"]) == "doing" then
            active[fmtInt(pull["db/id"])] = true
        end
    end
    local changed = false
    for id in pairs(S.taskStarts) do
        if not active[id] then
            S.taskStarts[id] = nil
            changed = true
        end
    end
    if changed then hs.settings.set(TASK_STARTS_KEY, S.taskStarts) end

    local meta = hs.json.encode({
        start = S.cache.start,
        ["end"] = S.cache["end"],
        end2 = S.cache.end2,
        ["until"] = S.cache["until"],
        done = S.done.items,
    })

    jsPanel("app.setData(" .. S.cache.raw .. "," .. meta .. ")")

    peek.update()
end


-- ============================================================
-- WINDOW POSITION
-- ============================================================

local function positionPopup(height)
    if not S.popup then
        return
    end

    local screen =
        hs.mouse.getCurrentScreen()
        or hs.screen.mainScreen()

    if not screen then
        return
    end

    local frame = screen:frame()

    local maxHeight = math.min(MAX_HEIGHT, frame.h - SCREEN_MARGIN * 2)

    height =
        math.max(
            MIN_HEIGHT,
            math.min(maxHeight, tonumber(height) or MIN_HEIGHT)
        )

    S.popup:frame({
        x = frame.x + frame.w - WIDTH - SCREEN_MARGIN,
        y = frame.y + frame.h - height - SCREEN_MARGIN,
        w = WIDTH,
        h = height,
    })
end


-- ============================================================
-- HIDE
-- ============================================================

function M.hide()
    if not S.popup or not S.visible then
        return
    end

    S.visible = false
    S.pendingShow = false
    S.canBlurClose = false
    S.blurPinned = false

    S.popup:hide()

    -- Re-arm only after pointer leaves the corner.
    S.cornerArmed = false

    hs.timer.doAfter(0.25, peek.update)
end


-- ============================================================
-- MESSAGES FROM JS
-- ============================================================

local function onPanelMessage(message)
    local body = message.body

    if type(body) ~= "table" then
        return
    end

    local action = body.action

    if action == "ready" then
        S.ready = true
        jsPanel("app.setDashboard(" .. hs.json.encode({ page = DASHBOARD_PAGE or "" }) .. ")")
        M.applyData()

        if S.pendingShow then
            S.pendingShow = false
            hs.timer.doAfter(0, function() M.show() end)
        end

    elseif action == "resize" then
        S.lastHeight = tonumber(body.height) or S.lastHeight

        if S.visible then
            positionPopup(S.lastHeight)
        end

    elseif action == "close" then
        M.hide()

    elseif action == "capture" then
        local kind = body.kind

        if kind == "note" or kind == "backlog" or kind == "page" then
            -- Web animation already finished.
            M.hide()
        end

        hs.timer.doAfter(0.01, function() actions.handleCapture(body) end)

    elseif action == "update" then
        actions.handleUpdate(body)

    elseif action == "refresh" then
        queue.requestRefresh()

    elseif action == "pinBlur" then
        S.blurPinned = body.on == true

    elseif action == "openUrl" then
        local url = tostring(body.url or "")

        if url:match("^https?://") then
            M.hide()
            hs.urlevent.openURL(url)
        end

    elseif action == "openBlock" then
        local uuid = tostring(body.uuid or "")

        if uuid:match("^[%x%-]+$") then
            M.hide()
            actions.openLogseqUrl("block-id=" .. uuid)
        end

    elseif action == "openPage" and DASHBOARD_PAGE then
        M.hide()
        actions.openLogseqUrl("page=" .. urlEncode(DASHBOARD_PAGE))

    else
        settings.handle(body)
    end
end


-- ============================================================
-- CREATE / SHOW WEBVIEW
-- ============================================================

function M.create()
    S.usercontent = hs.webview.usercontent.new("logseqCapture")

    S.usercontent:setCallback(function(message)
        local ok, err = pcall(onPanelMessage, message)

        if not ok then
            log("message error:", err)
        end
    end)

    S.popup = hs.webview.new(
        { x = 0, y = 0, w = WIDTH, h = MIN_HEIGHT },
        { javaScriptEnabled = true },
        S.usercontent
    )

    S.popup
        :windowStyle({ "borderless" })
        :allowTextEntry(true)
        :transparent(true)
        :shadow(false)
        :closeOnEscape(false)
        :level(hs.drawing.windowLevels.floating)

    -- Click anywhere outside → close.
    S.popup:windowCallback(function(action, _, state)
        if action == "focusChange"
            and state == false
            and S.visible
            and S.canBlurClose
            and not S.blurPinned
        then
            M.hide()
        end
    end)

    -- Preload while hidden.
    S.popup:html(assets.page("panel.html"))
end


function M.show()
    if S.visible then
        return
    end

    if not S.popup then
        M.create()
    end

    if not S.ready then
        S.pendingShow = true
        return
    end

    S.visible = true
    S.canBlurClose = false

    peek.hide()

    positionPopup(S.lastHeight)

    S.popup:show()
    S.popup:bringToFront(true)

    local window = S.popup:hswindow()

    if window then
        window:focus()
    end

    -- Prevent initial focus transition from closing it.
    hs.timer.doAfter(0.20, function()
        if S.visible then
            S.canBlurClose = true
        end
    end)

    hs.timer.doAfter(0.04, function()
        if S.popup and S.visible then
            jsPanel("app.reset()")
        end
    end)

    queue.requestRefresh()
end


function M.toggle()
    if S.visible then
        jsPanel("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}))")
    else
        M.show()
    end
end


return M

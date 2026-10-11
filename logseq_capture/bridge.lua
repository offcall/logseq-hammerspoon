-- ============================================================
-- LUA → JS BRIDGE
-- jsPanel / jsPeek call window.app.* / window.peek.* in the webviews.
-- ============================================================

local S = require("logseq_capture.state")

local M = {}


function M.jsPanel(code)
    if S.popup and S.ready then
        S.popup:evaluateJavaScript(
            "try{" .. code .. "}catch(e){console.error(e)}"
        )
    end
end


function M.jsPeek(code)
    if S.peek and S.peekReady then
        S.peek:evaluateJavaScript(
            "try{" .. code .. "}catch(e){console.error(e)}"
        )
    end
end


function M.notifyError(req, message)
    message = tostring(message or "unknown error")

    if S.visible then
        M.jsPanel(
            "app.result(" ..
            hs.json.encode({ req = req or 0, ok = false, message = message }) ..
            ")"
        )
    else
        hs.alert.show("❌ Logseq: " .. message, 3)
    end
end


return M

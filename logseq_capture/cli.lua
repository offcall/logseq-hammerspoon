-- ============================================================
-- LOGSEQ CLI RUNNER (async, single command)
-- ============================================================

local config = require("logseq_capture.config")
local S = require("logseq_capture.state")
local util = require("logseq_capture.util")

local LOGSEQ = config.LOGSEQ
local GRAPH = config.GRAPH
local CLI_TIMEOUT = config.CLI_TIMEOUT
local USER_SHELL = config.USER_SHELL
local log = util.log
local shellQuote = util.shellQuote

local M = {}


-- ============================================================
-- USER ENVIRONMENT
-- The CLI is a node script: it needs the PATH from your login shell.
-- Captured once (same path hs.execute(..., true) used before);
-- every CLI call then runs directly via hs.task, without a shell.
-- ============================================================

function M.captureUserEnv()
    local output, ok = hs.execute("/usr/bin/env", true)

    if not ok or not output then
        return nil
    end

    local env = {}

    for line in output:gmatch("[^\n]+") do
        local key, value = line:match("^([%a_][%w_]*)=(.*)$")

        if key then
            env[key] = value
        end
    end

    if not env.PATH or env.PATH == "" then
        return nil
    end

    env.NO_COLOR = "1"
    env.FORCE_COLOR = "0"

    return env
end


local function extractJson(output)
    if not output or output == "" then
        return nil
    end

    local i =
        output:find('{"status"', 1, true)
        or output:find("{", 1, true)

    if not i then
        return nil
    end

    local j = output:match("^.*()}")

    if not j or j < i then
        return nil
    end

    return output:sub(i, j)
end


function M.start(args, callback)
    local full = { "--graph", GRAPH, "--output", "json" }

    for _, arg in ipairs(args) do
        full[#full + 1] = tostring(arg)
    end

    local preview = {}
    for i, arg in ipairs(full) do
        local flat = arg:gsub("%s+", " ")
        preview[i] = #flat > 80 and (flat:sub(1, 77) .. "...") or flat
    end
    log("RUN:", LOGSEQ .. " " .. table.concat(preview, " "))

    local finished = false
    local task
    local watchdog

    local function finish(code, stdout, stderr)
        if finished then
            return
        end

        finished = true
        stdout = stdout or ""
        stderr = stderr or ""

        if watchdog then
            watchdog:stop()
        end

        if S.currentTask == task then
            S.currentTask = nil
        end

        local raw = extractJson(stdout)
        local decoded

        if raw then
            local okDecode, value = pcall(hs.json.decode, raw)

            if okDecode and type(value) == "table" then
                decoded = value
            else
                raw = nil
            end
        end

        local ok =
            code == 0 and
            decoded ~= nil and
            decoded.status == "ok"

        local message

        if not ok then
            if decoded and type(decoded.error) == "table" then
                message = decoded.error.message or decoded.error.code
            end

            if not message or message == "" then
                message = (stderr ~= "" and stderr) or (stdout ~= "" and stdout) or ("exit code " .. tostring(code))
            end

            message = tostring(message):gsub("%s+", " "):sub(1, 220)

            log("FAILED (" .. tostring(code) .. ")")
            if stdout ~= "" then print(stdout) end
            if stderr ~= "" then print(stderr) end
        end

        local okCb, err = pcall(callback, ok, raw, decoded, message)

        if not okCb then
            log("callback error:", err)
        end
    end

    if S.env then
        task = hs.task.new(LOGSEQ, finish, full)

        if task then
            task:setEnvironment(S.env)
        end
    else
        -- Fallback: same login+interactive shell hs.execute(cmd, true) uses.
        local parts = { shellQuote(LOGSEQ) }

        for _, arg in ipairs(full) do
            parts[#parts + 1] = shellQuote(arg)
        end

        task = hs.task.new(
            USER_SHELL,
            finish,
            { "-l", "-i", "-c", table.concat(parts, " ") }
        )
    end

    if not task then
        finish(-1, "", "could not create hs.task")
        return
    end

    S.currentTask = task

    if not task:start() then
        finish(-1, "", "could not start " .. LOGSEQ)
        return
    end

    watchdog = hs.timer.doAfter(CLI_TIMEOUT, function()
        if finished then
            return
        end

        log("TIMEOUT after " .. CLI_TIMEOUT .. "s")

        pcall(function()
            if task:isRunning() then
                task:terminate()
            end
        end)

        hs.timer.doAfter(2, function()
            finish(-1, "", "timed out after " .. CLI_TIMEOUT .. "s")
        end)
    end)
end


return M

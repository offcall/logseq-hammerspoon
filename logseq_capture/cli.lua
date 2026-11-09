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

    -- Output goes to temp files, read after exit: a pipe deadlocks once the
    -- CLI fills its 64 KB buffer, and streamed chunks can arrive after the
    -- exit callback or split a UTF-8 character.
    local outPath, errPath = os.tmpname(), os.tmpname()

    local function readAndRemove(path)
        local file = io.open(path, "rb")
        local data = file and file:read("*a") or ""

        if file then
            file:close()
        end

        os.remove(path)
        return data
    end

    local function finish(code, stdout, stderr)
        if finished then
            return
        end

        finished = true
        stdout = readAndRemove(outPath) .. (stdout or "")
        -- Own messages (timeout, start failure) first: the toast is cut at 220 chars.
        local errFile = readAndRemove(errPath)
        stderr = stderr or ""
        if errFile ~= "" then
            stderr = stderr ~= "" and (stderr .. "\n" .. errFile) or errFile
        end

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
        -- sh only adds the redirects; paths and args stay positional, unquoted.
        local argv = {
            "-c", 'out=$1 err=$2; shift 2; exec "$@" >"$out" 2>"$err"',
            "sh", outPath, errPath, LOGSEQ,
        }

        for _, arg in ipairs(full) do
            argv[#argv + 1] = arg
        end

        task = hs.task.new("/bin/sh", finish, argv)

        if task then
            task:setEnvironment(S.env)
        end
    else
        -- Fallback: same login+interactive shell hs.execute(cmd, true) uses.
        local parts = { shellQuote(LOGSEQ) }

        for _, arg in ipairs(full) do
            parts[#parts + 1] = shellQuote(arg)
        end

        parts[#parts + 1] = ">" .. shellQuote(outPath)
        parts[#parts + 1] = "2>" .. shellQuote(errPath)

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

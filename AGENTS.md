# AGENTS.md

Persistent instructions for coding agents in this repository. See `docs/adr/` for
architectural decisions.

## Project

Control Logseq from macOS with [Hammerspoon](https://www.hammerspoon.org/). The main
artifact is a single Lua script, `logseq_capture.lua`, with a "Capture + Today" panel
in the bottom-right corner of the screen.

The project grows by small, useful features on top of the official Logseq CLI, not
by rewrites. Agents implement one requested task at a time and keep the script
working after every change.

## Environment

- Hammerspoon. Installation and the Hammerspoon config are managed by the user:
  do not edit `~/.hammerspoon/`, reload Hammerspoon, or send it commands. Work only on
  `logseq_capture.lua` in this repository.
- Logseq (DB version). Graph, dashboard page, CLI path, and open hotkey come from
  `~/.hammerspoon/logseq_capture_config.lua`, created by `install.sh`; defaults
  are at the top of the script (ADR 0006).
- The CLI is a node script and needs the login-shell `PATH`; the script captures the
  env once via `hs.execute("/usr/bin/env", true)`.
- UI and all artifacts are in English.

## Script architecture

One Lua file; the panels' HTML/CSS/JS is embedded as long strings (`[==[ ... ]==]`).

- **Panel** (`hs.webview`, `S.popup`) — capture textarea plus the task list
  (Expired · In progress · Today · Tomorrow · Done today). Opened by the hot corner
  (`CORNER_SIZE` / `REARM_DISTANCE`) or the optional `OPEN_HOTKEY`. Closes on Esc or
  focus loss.
- **Peek** (`S.peek`) — small pill with the current Doing task (pause/done buttons,
  click opens the panel). The window is `nonactivating`.
- **State** — global table `_G.logseqCapture` (local alias `S`). The cleanup block at
  the top of the file stops timers, the hotkey, the running `hs.task`, and deletes
  webviews of the previous instance on reload. Every new long-lived object (timer,
  webview, hotkey, watcher) must be added to that cleanup.
- **JS ↔ Lua bridge** — JS → Lua via
  `window.webkit.messageHandlers.{logseqCapture,logseqPeek}.postMessage({action, ...})`;
  Lua → JS via `evaluateJavaScript` (`jsPanel` / `jsPeek` call `window.app.*` /
  `window.peek.*`).

## Working with Logseq

- Only through the official CLI: `logseq --graph <graph> --output json <cmd> ...`.
  No direct edits of graph files, no HTTP API.
- Calls are async (`hs.task`) and strictly sequential: queue `S.queue` + `pump()`.
  Timeout `CLI_TIMEOUT` (the first call may start the db-worker).
- Refresh is one datalog query, `TASKS_QUERY`. Its input `?end2` is the start of the
  day after tomorrow (local time, epoch ms). A refresh result is dropped if writes
  were queued meanwhile, so optimistic UI is never overwritten by stale data.
- Commands in use: `query`; `upsert task` (`--uuid` / `--id`, `--status`,
  `--deadline` / `--scheduled` in epoch ms, `--no-deadline` / `--no-scheduled`);
  `upsert block --content` (journal note); `upsert page --page`.
- Opening in the app: `logseq://graph/<graph>?block-id=...` / `?page=...`.
- Done tasks leave the query, so "Done today" is stored locally in `hs.settings`
  (`logseqCapture.doneToday`) and reset when the day changes.

## Conventions

- Dates are local midnight in epoch ms (`dayStartMs` in Lua, `dayStart` / `addDays`
  in JS).
- The UI is optimistic: changes apply in JS immediately; CLI errors come back via
  `app.result({req, ok: false, message})` and show as a toast.
- When changing hotkeys, update the header comment of the script and the footer
  (`renderFoot`).
- Validate by reloading the Hammerspoon config and reading the console: logs are
  prefixed `[Logseq Panel]`, every CLI call is logged as `RUN:`.

## Language

All development artifacts are written in English: source code, identifiers,
comments, documentation, README files, ADRs, commit messages, tests, agent
instructions, and developer-facing error messages. Do not add non-English
development documentation unless explicitly requested.

## Code quality

Code must be readable, modular, easy to understand and modify, and separated by
responsibility. Prefer straightforward solutions over unnecessary abstraction.

## Minimal changes

Make the smallest change that completes the current task correctly. Do not:

- perform unrelated refactors;
- rename unrelated files;
- reformat unrelated code;
- change public interfaces unnecessarily;
- introduce dependencies without a clear reason;
- modify unrelated behavior.

Respect the existing architecture unless an ADR documents a reason to change it.

## ADR rules

`docs/adr/` is the persistent architectural memory of the repository. A decision
that materially affects architecture, dependencies, interfaces, or workflow needs a
new ADR before or together with the implementation. For such a decision:

1. Inspect existing ADRs.
2. Check whether the decision is already documented.
3. Create a new ADR for a meaningful new decision and add it to `docs/adr/README.md`.
4. Never silently rewrite historical ADRs.
5. Supersede old ADRs with new ones when a decision changes.

## Incremental development

Work in small steps: inspect → plan → implement → validate → commit and push →
report.

- One logical change per commit.
- Conventional Commit messages: `<type>(<scope>): <short description>`, lowercase
  scope, e.g. `fix(peek): hide pill when no doing task`.
- Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.
- Push completed commits to `main`.

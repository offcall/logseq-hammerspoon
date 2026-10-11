# ADR 0006: Install as a module with a separate user config

## Status

Accepted. Supersedes [ADR 0002](0002-install-config-with-a-shell-script.md).

## Context

The project is being published for other users. ADR 0002 installs the script by
replacing `~/.hammerspoon/init.lua`, which would wipe an existing Hammerspoon
config. The CLI path, graph, and dashboard page are edited at the top of the
script, so every update overwrites them, and the defaults point to one user's
machine and pages.

## Decision

- `install.sh` copies `logseq_capture.lua` to `~/.hammerspoon/` and makes
  `init.lua` load it with `require("logseq_capture")`. An existing `init.lua` is
  backed up and the line is appended once; an `init.lua` that is an old full copy
  of the script is replaced by that line.
- Settings live in `~/.hammerspoon/logseq_capture_config.lua`, a Lua file that
  returns a table (`logseq`, `graph`, `dashboardPage`, `openHotkey`). The script
  falls back to built-in defaults for missing keys or a missing file.
- The installer creates the config once: graph and dashboard page come from
  `LOGSEQ_GRAPH` / `LOGSEQ_DASHBOARD` or a prompt, the CLI path from the login
  shell `PATH`. Updates never touch it.
- `dashboardPage = false` hides the dashboard button; the button shows the page
  name.
- The installer also works without a clone: `curl -fsSL <raw install.sh> | bash`
  downloads the script from `main`. Its body runs in a `main` function so a
  partial download does nothing.
- Hammerspoon is still restarted with standard AppleScript and `open`.

## Consequences

- Installing does not destroy other Hammerspoon setups; updates keep settings.
- The one-line install fetches the current `main`, not a tagged release.
- The script now reads a file outside the repository at load time; a broken
  config shows an alert and falls back to defaults.

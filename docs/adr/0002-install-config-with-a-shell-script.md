# ADR 0002: Install config with a shell script

## Status

Superseded by [ADR 0006](0006-install-as-module-with-user-config.md)

## Context

The current Hammerspoon config is a copy of `logseq_capture.lua` installed as
`~/.hammerspoon/init.lua`. Updating it requires copying the file and reloading
the config. The user wants one command for both steps.

## Decision

Provide a user-run `install.sh` that backs up the existing `init.lua`, replaces
it with the repository script, and quits and starts Hammerspoon to load it.

Use standard macOS AppleScript and `open`, avoiding a Hammerspoon CLI dependency
or enabling external Lua execution through AppleScript.

## Consequences

- Installation and subsequent updates use the same command.
- The entire `init.lua` is replaced; existing configs remain in backup files.
- Hammerspoon is restarted rather than only reloading its Lua environment.
- Agents can validate the installer with mocked commands without changing the
  user's config or controlling Hammerspoon.

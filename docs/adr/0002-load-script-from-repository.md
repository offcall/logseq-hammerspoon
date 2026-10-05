# ADR 0002: Load the script from the repository

## Status

Accepted

## Context

The capture panel script lived directly in `~/.hammerspoon/init.lua`, outside version
control. Edits there are not tracked, and the repository copy would drift from what
Hammerspoon actually runs.

## Decision

The script lives in the repository as `logseq_capture.lua` and is the single source
of truth. `~/.hammerspoon/init.lua` only loads it:

```lua
dofile(os.getenv("HOME") .. "/projects/logseq-hammerspoon/logseq_capture.lua")
```

`dofile` with an explicit path is used instead of a symlink or `require`, so the rest
of the Hammerspoon config stays independent of this repository and every reload
re-reads the file.

## Consequences

- Changes are made in the repository and take effect on Hammerspoon reload.
- The repository path is fixed in `init.lua`; moving the repository means updating
  that line.
- Other Hammerspoon modules can live in `init.lua` next to the loader line.

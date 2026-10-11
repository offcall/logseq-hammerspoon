# ADR 0007: Split the script into a module directory

## Status

Accepted. Supersedes the "copies `logseq_capture.lua`" part of
[ADR 0006](0006-install-as-module-with-user-config.md); the user config and
`init.lua` handling stay as decided there.

## Context

`logseq_capture.lua` grew to over 3000 lines. More than half of it is the
panel's HTML/CSS/JS embedded as Lua long strings, which editors cannot
highlight or lint, and the Lua part mixes config, CLI runner, queue, webviews,
and the hot corner in one scope. Changes are hard to review and to locate.

## Decision

- The script becomes a Lua package directory `logseq_capture/`:
  `init.lua` (entry and wiring) plus one module per responsibility
  (`config`, `state`, `util`, `bridge`, `cli`, `done`, `tasks`, `queue`,
  `actions`, `peek`, `panel`, `corner`, `assets`). Modules are loaded with
  `require("logseq_capture.<name>")`; `require("logseq_capture")` in the user's
  `init.lua` keeps working through Hammerspoon's `?/init.lua` search path.
- The web UI lives in plain files under `logseq_capture/web/`
  (`panel.html`, `panel.css`, `panel.js`, `peek.html`, `peek.css`, `peek.js`).
  At load time `assets.lua` reads an HTML file and inlines its
  `<link rel="stylesheet">` and `<script src>` files, so the webviews still get
  one HTML string through `hs.webview:html()`. No build step, no framework, no
  new dependencies.
- `install.sh` installs the whole directory: from a clone with `cp -R`, otherwise
  from the GitHub tarball of `main` (`curl | tar`). The new directory is staged in
  a temporary location and swapped in, and the old single-file
  `~/.hammerspoon/logseq_capture.lua` is removed so `require` cannot pick it up.

## Consequences

- HTML/CSS/JS get normal editor support; Lua modules are small and named by
  responsibility.
- Shared state is still the global `_G.logseqCapture`; cycles between modules
  are broken by passing callbacks from `init.lua` instead of mutual `require`.
- The one-line install downloads a tarball instead of one file and depends on
  the repository and branch name (`logseq-hammerspoon-main/`).
- Local edits inside `~/.hammerspoon/logseq_capture/` are replaced on update,
  as the single file was before.

# logseq-hammerspoon

A quick-capture and "today" task panel for [Logseq](https://logseq.com/) (DB version)
on macOS, built on [Hammerspoon](https://www.hammerspoon.org/). Push the mouse into
the bottom-right corner, type, press a shortcut — the note or task is in Logseq
without switching windows.

![Capture + Today panel and the Doing pill](docs/screenshot.png)

- **Capture** — a note to today's journal, a task for today, tomorrow, or any date,
  a backlog task, or a new page.
- **Task list** — Expired · In progress · Today · Tomorrow · Done today, plus a
  two-week calendar view. Start, finish, reschedule, search, and undo from the
  keyboard.
- **Peek** — a small pill in the corner with your current "Doing" tasks and timers.

## Quick start

1. Install [Hammerspoon](https://www.hammerspoon.org/), Logseq (DB version), and the
   Logseq CLI (needs Node.js on your login-shell `PATH`).
2. Free the bottom-right hot corner: macOS uses it for **Quick Note** by default.
   Open **System Settings → Desktop & Dock → Hot Corners…** and set the bottom-right
   corner to **–**.
3. Run:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/offcall/logseq-hammerspoon/main/install.sh | bash
   ```

   The installer lists your local graphs, asks which one to use and which page the
   panel's top-right button opens (it checks that the page exists and suggests
   similar names), then restarts Hammerspoon. To skip the questions:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/offcall/logseq-hammerspoon/main/install.sh \
     | LOGSEQ_GRAPH="My graph" LOGSEQ_DASHBOARD="Dashboard" bash
   ```

4. Move the mouse into the bottom-right corner. macOS may ask you to allow
   Hammerspoon Accessibility access and your terminal to control Hammerspoon.

Run the same command to update. From a clone, `./install.sh` does the same with the
local files.

### What the installer changes

- `~/.hammerspoon/logseq_capture.lua` — the script, replaced on every update.
- `~/.hammerspoon/logseq_capture_config.lua` — your settings, created once and never
  overwritten.
- `~/.hammerspoon/init.lua` — gets one line, `require("logseq_capture")`. The rest of
  your Hammerspoon config stays; the previous file is saved as
  `init.lua.backup.XXXXXX`.

## Configuration

Edit `~/.hammerspoon/logseq_capture_config.lua` and reload Hammerspoon:

```lua
return {
    logseq = "/Users/you/.local/bin/logseq",  -- Logseq CLI
    graph = "My graph",                       -- graph to read and write
    dashboardPage = "Dashboard",              -- page for the top-right button; false hides it
    openHotkey = { {"cmd", "alt"}, "L" },     -- optional hotkey to toggle the panel
}
```

`dashboardPage` can be any page in your graph — a dashboard, an inbox, a weekly
review. The button shows that page's name and opens it in Logseq; set it to `false`
if you don't need it.

## Keyboard shortcuts

| Where | Keys |
| --- | --- |
| Capture | `↩` note · `⇧↩` newline · `⌘T` today · `⌘⇧T` tomorrow · `⌘D` date · `⌘B` backlog · `⌘P` page · `↓` / `Tab` to the list |
| List | `↑↓` / `j k` move · `Space` / `x` done · `s` start/pause · `t` tomorrow · `d` reschedule · `b` backlog · `↩` / `o` open in Logseq |
| Anywhere | `⌘Z` undo · `⌘R` refresh · `⌘F` search · `c` list/calendar · `/` or `n` back to input · `Esc` close |

## How it works

The panel talks to Logseq only through the official CLI
(`logseq --graph <name> --output json ...`), called asynchronously one command at a
time. It never edits graph files directly. Logs appear in the Hammerspoon console
with the `[Logseq Panel]` prefix.

Significant decisions are recorded in [`docs/adr/`](docs/adr/).

## License

[MIT](LICENSE)

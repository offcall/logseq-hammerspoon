# logseq-hammerspoon

Control [Logseq](https://logseq.com/) from macOS with [Hammerspoon](https://www.hammerspoon.org/).

## What it is

A Hammerspoon Lua script (not yet in this repository) that adds a quick capture and
"today" panel for a Logseq (DB version) graph:

- **Capture panel** — opens from the bottom-right hot corner. Type a note, a task for
  today or tomorrow, a backlog task, or a new page, and send it to Logseq with a
  keyboard shortcut.
- **Task list** — expired, in-progress, today, tomorrow, and done-today tasks, with
  keyboard actions to start, finish, reschedule, or move tasks to the backlog.
- **Peek** — a small pill in the bottom-right corner showing the current "Doing" task.

## Why it exists

Capturing a thought or checking today's tasks should not require switching to the
Logseq window. The panel keeps that loop to a hot corner and a few keystrokes.

## How it talks to Logseq

Only through the official Logseq CLI (`logseq --graph <name> --output json ...`),
called asynchronously from Hammerspoon one command at a time. The script does not
edit graph files directly.

## Requirements

- macOS with Hammerspoon
- Logseq (DB version) and its CLI (requires Node.js on the login-shell `PATH`)
- A graph to work with (configured at the top of the script)

Installation steps will be added together with the script.

## Status and direction

The repository is being set up. The script will be added and then developed in
small, incremental steps. Significant decisions are recorded as Architecture
Decision Records in [`docs/adr/`](docs/adr/).

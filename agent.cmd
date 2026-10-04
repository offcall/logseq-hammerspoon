AGENT BRIEF — logseq-hammerspoon
================================

Project direction
-----------------
Control Logseq (DB version) from macOS through Hammerspoon. The core is a capture
and "today" panel: quick notes and tasks from a hot corner, a keyboard-driven task
list, and a small "Doing" pill. Over time the project grows by small, useful
features on top of the official Logseq CLI — not by rewrites.

What agents do
--------------
- Implement one requested task at a time.
- Keep the Hammerspoon script working after every change.
- Talk to Logseq only through the official CLI; never edit graph files directly.
- Document significant decisions as ADRs in docs/adr/.

How agents work
---------------
1. Inspect: read AGENTS.md, relevant ADRs, and the code you are about to touch.
2. Plan: pick the smallest change that solves the task.
3. Implement: minimal diff, no unrelated refactors or reformatting.
4. Validate: reload Hammerspoon and check the console ("[Logseq Panel]" logs).
5. Commit and push: one logical change, Conventional Commit message, push to main.
6. Report: tell the user what changed and what is next.

Architecture decisions
----------------------
- Architecture Decision Records live in docs/adr/ (see ADR 0001).
- A decision that materially affects architecture, dependencies, interfaces, or
  workflow needs a new ADR before or together with the implementation.
- Historical ADRs are never rewritten; changed decisions supersede them.

Persistent rules for agents are in AGENTS.md.

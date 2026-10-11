# ADR 0005: Two-week calendar view in the panel

## Status

Accepted

## Context

The panel lists tasks only up to tomorrow (Expired · In progress · Today ·
Tomorrow · Done today). The user wants a compact calendar dashboard that shows
tasks by day, so the load of the coming days is visible at a glance.

## Decision

Add a second view mode to the existing panel instead of a new window:

- A calendar button next to search and sort (key `C`) toggles List ↔ Calendar.
- Calendar mode shows a Monday-first grid of the current and the next week
  (14 cells) between the task tools and the list. Each cell shows the number of
  open tasks and a load bar; past days are dimmed and show overdue counts in red.
- The list under the grid shows the tasks of the selected day (today by
  default). A task belongs to the day of its earliest date (deadline or
  scheduled). Today also lists "Done today".
- `TASKS_QUERY` input changes from "day after tomorrow" to the end of the grid
  window (`?until`, Monday of the week after next). List mode still filters by
  `end2` on the JS side, so its content does not change.

## Consequences

- One query still feeds both modes; it returns more rows (up to two weeks ahead).
- Tasks overdue from before the grid start are not shown in the grid; the day
  header links back to List mode, where Expired lists them.
- Done tasks exist only for today (`logseqCapture.doneToday`), so past days do
  not show completed work.
- Undated Doing tasks appear only in List mode.

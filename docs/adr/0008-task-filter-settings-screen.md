# ADR 0008: Task filter on a settings screen

## Status

Accepted.

## Context

The refresh query was a constant: open statuses `todo`, `backlog`, `doing`,
`in-review`, a `#Task` without a status as todo, Doing tasks always and other
tasks only when dated. That fits one user's workflow; other users track tasks
differently. A datalog query is easy to get wrong, so a user who edits it needs
to see its result before it replaces the panel's data.

## Decision

- The panel gets a settings screen (gear in the header, `⌘,`) in the same
  webview. It sets the task filter:
  - mode `statuses`: checkboxes for the values of the Status property, loaded
    from the graph with a `query`; `done` and `canceled` are closed and not
    selectable, because done tasks are tracked locally ("Done today"). A
    switch decides whether a `#Task` without a status counts as todo. The
    query is built from a template; the default filter gives the old query.
  - mode `custom`: the user's own datalog query, prefilled from the statuses.
    It must keep the pull pattern and `:in $ ?until` of the template.
- **Test** runs the query through the CLI queue and shows the count, a few
  titles, or the error; rows that are not `(pull ?task [...])` maps with
  `:db/id` fail the test. **Save** is enabled only after a passing test of the
  exact current filter.
- The filter is stored in `hs.settings` per graph
  (`logseqCapture.taskFilter.<graph>`), not in the user config file: the script
  never rewrites that Lua file. **Reset to default** clears the stored filter.
- Module `filter.lua` owns the template, the defaults, and storage;
  `settings.lua` handles the screen's messages. The installer only prints where
  the setting is.

## Consequences

- Users choose their tasks without editing files, and updates keep the choice.
- The filter is not in the config file, so it is not copied with it to another
  Mac.
- A saved custom query can still break later (for example after a Logseq
  schema change); the panel then shows the refresh error as before.

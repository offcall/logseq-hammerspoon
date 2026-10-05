---
name: adr-repository-initialization
description: Initializes an existing GitHub repository for ADR-driven development (README, .gitignore, AGENTS.md, first ADR). Use only when the user explicitly writes "init ADR in this repository" and provides a repository URL. Do not trigger on general mentions of ADRs, READMEs, or repositories.
---

# ADR Repository Initialization

## Purpose

Prepare an existing GitHub repository for structured, ADR-driven development:
document the project, set repository hygiene, write persistent instructions
for coding agents, and record the first Architecture Decision Record.

The repository URL comes from the user and is different every time. Never
hardcode a repository, project name, or project purpose into the output.

## Trigger

Run this skill only when the user explicitly writes:

`init ADR in this repository <repository-url>`

Do not infer this intent when the user merely mentions ADRs, shares a
repository, asks for a README, or asks to initialize or document a project.

If the command is given without a URL, ask for the URL before doing anything.

---

## Core Rules

### Orchestration and subagents

When the environment supports subagents, the main agent orchestrates and
delegates implementation work. When it does not, the main agent does the work
itself, following the same steps.

The main agent is responsible for planning, sequencing, deciding what context
each subagent needs, validating results, committing, and reporting to the user.

For each delegated task:

- give the subagent only the context required for that task;
- ask it to inspect the relevant repository files before changing anything;
- review its output before committing; do not commit unreviewed changes.

### Git safety

- Inspect the repository state (`git status`, branches, existing files) before
  modifying anything.
- Work on `main` and push completed commits to `main`, unless the repository
  has branch protection or other constraints. In that case, use a branch and
  tell the user.
- Never force-push, rewrite history, or delete files without explicit user
  approval.
- Never overwrite an existing useful file without reviewing it first; improve
  it instead.

### Commits

One logical change per commit, using Conventional Commits:

`<type>(<scope>): <short description>`

- Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.
- Scope and description in lowercase, concise.
- Do not combine unrelated work in one commit.
- If a step produces no changes (the file is already adequate), skip its
  commit and say so in the status update.

### Language

All repository artifacts are written in English: code, identifiers, comments,
documentation, ADRs, commit messages, tests, and agent instructions. Status
updates to the user may use the user's language.

---

## Initialization Sequence

Perform the steps in order. After each step, commit, push, and send a status
update (see "Status Updates").

### Step 0 — Open the repository

Clone the repository from the given URL, or open an existing local checkout.
For an existing checkout, verify that `git remote get-url origin` points to
the given URL; if it does not, stop and ask the user. Then inspect the
repository state as described in "Git safety". This step has no commit.

### Step 1 — README.md

Create or improve `README.md`. Base it only on what the repository and the
user actually show. It should explain:

- what the project is;
- why it exists and what problem it solves;
- its current state;
- planned direction, only if known.

Do not invent functionality, purpose, or roadmap. If the purpose cannot be
determined from the code and existing docs, ask the user before writing it.

Commit: `docs(readme): describe project purpose`

### Step 2 — .gitignore

Detect the technology stack from existing files. Create or extend
`.gitignore` to exclude dependencies, build output, generated files, local
configuration, credentials and secrets, temporary files, and IDE/OS artifacts.

Extend an existing `.gitignore` rather than replacing it. If tracked files
would now be ignored (for example a committed secret), report it to the user
instead of silently untracking it.

Commit: `chore(gitignore): add repository ignore rules`

### Step 3 — AGENTS.md

Create or update `AGENTS.md`. This is the single source of persistent
instructions for coding agents. Preserve useful existing content.

It must contain the sections from the "AGENTS.md Content" section below.

If the repository already has `CLAUDE.md` or other agent instruction files,
do not duplicate rules across them. Keep the rules in `AGENTS.md` and make the
other file reference it (for `CLAUDE.md`, a line containing `@AGENTS.md`).

Commit: `docs(agents): define agent development workflow`

Present `AGENTS.md` to the user for review. Continue with the remaining
initialization steps, but do not start development work (see "Development
After Initialization") until the user has reviewed it.

### Step 4 — ADR 0001

Create `docs/adr/` with:

- `docs/adr/README.md` — a short index explaining what ADRs are in this
  repository, the file naming scheme (`NNNN-kebab-case-title.md`), and a list
  of existing ADRs;
- `docs/adr/0001-use-architecture-decision-records.md` — the first ADR.

If the repository already has ADRs or a decisions directory, adopt its
location, naming, and numbering instead of creating a parallel one: add the
ADR under the next free number, and skip it entirely if adopting ADRs is
already recorded. Update the existing index rather than creating a new one.

Every ADR contains at least: Title, Status, Context, Decision, Consequences.

Template for ADR 0001:

```md
# ADR 0001: Use Architecture Decision Records

## Status

Accepted

## Context

The project needs a lightweight, persistent way to record important
architectural and engineering decisions. Decisions made only in conversations
or agent sessions are easily lost and hard to reconstruct later.

## Decision

We will record architectural decisions as ADRs in `docs/adr/`.

An ADR is required for decisions that materially affect architecture,
development workflow, dependencies, interfaces, or long-term maintainability.
ADRs are short and focused on one decision each.

## Consequences

- Important decisions stay discoverable in the repository.
- Future contributors and agents can see why a decision was made.
- Accepted ADRs are not rewritten; a changed decision gets a new ADR that
  supersedes the old one.
- Writing ADRs becomes part of the normal development workflow.
```

Commit: `docs(adr): adopt architecture decision records`

Present ADR 0001 to the user for review.

### Step 5 — Review pass (optional)

If review skills are available in the environment (for example a
simplification review, a README review, or an AGENTS.md review), run them
against the new files.

Apply only justified suggestions. Every resulting change still follows the
core rules: minimal, English-only, one commit per logical change, with the
scope of the file it touches (for example `docs(readme): ...`). Do not run
this step if no such skills are available, and do not invent substitutes.

---

## AGENTS.md Content

`AGENTS.md` must include the following sections. Adapt wording to the
project, but keep the rules.

### Project Direction

A short description of what the project is, where it is heading (only if
known), and what coding agents are expected to help with.

### Language

All development artifacts are written in English: source code, identifiers,
comments, documentation, ADRs, commit messages, tests, and agent
instructions.

### Code Quality

Code must be readable, modular, easy to change, and separated by
responsibility. Prefer straightforward solutions over unnecessary
abstraction.

### Minimal Changes

Make the smallest change that correctly completes the current task. Do not:

- refactor, rename, or reformat unrelated code;
- change public APIs without need;
- add dependencies without a clear reason;
- change unrelated behavior.

Respect the existing architecture unless an ADR documents a reason to change
it.

### ADR Rules

Before implementing a significant architectural decision:

1. Read the existing ADRs in `docs/adr/`.
2. Check whether the decision is already documented.
3. If it is new, write a new ADR before or alongside the implementation and
   add it to `docs/adr/README.md`.
4. Never rewrite an accepted ADR's decision; supersede it with a new ADR and
   change only the old one's Status to `Superseded by ADR NNNN`.

Treat `docs/adr/` as the repository's persistent architectural memory.

### Workflow

Work in small steps:

`inspect → plan → implement → validate → commit and push → report`

Each commit is one understandable unit of work with a Conventional Commit
message (`<type>(<scope>): <short description>`, types `feat`, `fix`, `docs`,
`refactor`, `test`, `chore`).

---

## Development After Initialization

Implement further requests one task at a time:

1. Inspect the relevant repository state.
2. Read `AGENTS.md` and the relevant ADRs.
3. Delegate implementation to a subagent when supported, with only the
   context it needs.
4. Make the smallest correct change.
5. Validate it (run tests, linters, or the build when they exist).
6. Commit as one focused Conventional Commit and push.
7. Report the result to the user.
8. Move to the next task.

Do not batch unrelated tasks into one run or one commit.

---

## Status Updates

Send a short update after every completed unit of work. Do not hide several
completed steps behind one final message.

Completed:

```
✅ README initialized
Commit: docs(readme): describe project purpose
Pushed to main.
```

Awaiting review:

```
🟡 AGENTS.md created
Commit: docs(agents): define agent development workflow
Pushed to main. Ready for your review.
```

```
🟡 ADR 0001 created: Use Architecture Decision Records
docs/adr/0001-use-architecture-decision-records.md
Commit: docs(adr): adopt architecture decision records
Pushed to main. Ready for your review.
```

---

## Never

- Treat initialization as permission to rewrite the project.
- Hardcode a repository URL, project name, or project purpose.
- Invent project functionality or roadmap.
- Duplicate agent rules across several files.
- Force-push or rewrite history without explicit approval.

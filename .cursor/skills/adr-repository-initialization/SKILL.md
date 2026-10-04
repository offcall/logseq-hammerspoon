---
name: adr-repository-initialization
description: Initializes an existing GitHub repository for ADR-driven development. Use only when the user explicitly writes "init ADR in this repository" and provides a repository URL.
---

# ADR Repository Initialization Skill

## Purpose

Initialize an existing GitHub repository for structured, ADR-driven development.

This skill prepares the repository, establishes documentation and coding conventions, creates the first ADR, and defines how all future development must be performed.

The repository URL is provided by the user and may be different every time.

Example:

`https://github.com/offcall/logseq-hammerspoon`

---

## Explicit Trigger

This skill MUST run only when the user explicitly writes:

`init ADR in this repository`

Do not infer this intent from similar requests.

Do not automatically invoke this skill when the user merely:

- mentions ADRs;
- provides a GitHub repository;
- asks to modify a repository;
- asks to create a README;
- asks to initialize a project;
- asks to document architectural decisions.

The exact initialization intent must be explicitly provided by the user.

---

## Input

The skill expects:

1. A GitHub repository URL.
2. The explicit command:

   `init ADR in this repository`

Example:

`init ADR in this repository https://github.com/offcall/logseq-hammerspoon`

The repository URL must NOT be hardcoded because a different repository may be supplied next time.

---

# Core Execution Rules

## 1. Use subagents

The main agent should act as an orchestrator.

Implementation work should be delegated to subagents whenever the environment supports subagents.

The main conversation context should remain as clean as possible.

For every delegated task:

- provide the subagent only the context required for that task;
- retrieve additional repository context only when necessary;
- avoid dumping the entire conversation into the subagent;
- ask the subagent to inspect the relevant repository files before making changes;
- return the result to the main agent for validation.

The main agent remains responsible for:

- planning;
- sequencing;
- validating work;
- deciding what context subagents need;
- reviewing changes before committing;
- reporting progress to the user.

---

# Repository Initialization

After receiving the repository URL:

1. Clone or open the repository.
2. Inspect the existing repository before modifying anything.
3. Never overwrite existing useful files without reviewing them.
4. Work directly against the repository's `main` branch unless repository constraints require otherwise.
5. Push completed initialization commits to `main`.
6. Keep commits intentionally small and focused.

Before any destructive or potentially unsafe Git operation, inspect the repository state first.

---

# Commit Rules

All work must be divided into small, logically independent commits.

Use Conventional Commit-style messages.

Format:

`<type>(<short task>): <short description>`

Examples:

`docs(readme): describe project purpose`

`chore(gitignore): add repository ignore rules`

`docs(agent): document development workflow`

`docs(adr): adopt architecture decision records`

Rules:

- use lowercase task/scope names;
- keep commit messages concise;
- one logical change per commit;
- do not combine unrelated work;
- avoid large initialization commits when the work can be split;
- push completed commits to `main`.

Use appropriate commit types such as:

- `feat`
- `fix`
- `docs`
- `refactor`
- `test`
- `chore`

---

# Initialization Sequence

## Step 1 — README

Create or improve `README.md`.

The README must explain:

- what the project is;
- why it exists;
- its current purpose;
- the project's future direction when known;
- how the repository is intended to evolve.

For the example project, document that its purpose is related to AI-agent analytics if that remains consistent with the actual project context.

Do not invent unsupported project functionality.

Add only useful documentation.

Commit separately.

Example:

`docs(readme): describe project purpose`

---

## Step 2 — .gitignore

Inspect the technology stack and existing files.

Create or update `.gitignore` using rules appropriate for the repository.

Do not blindly replace an existing `.gitignore`.

Ensure generated files, local configuration, dependencies, credentials, temporary files, IDE artifacts, and build outputs are excluded where appropriate.

Commit separately.

Example:

`chore(gitignore): add repository ignore rules`

---

## Step 3 — agent.cmd

Create:

`agent.cmd`

The file must describe:

- the long-term direction of the project;
- what coding agents are expected to do;
- how agents should approach implementation;
- that Architecture Decision Records are used;
- that important architectural decisions must be documented;
- that development should proceed incrementally;
- that implementation should favor minimal changes.

Before proceeding to major implementation work, present `agent.cmd` to the user for review when practical.

Commit separately.

Example:

`docs(agent): define agent development workflow`

---

# ADR Setup

Create an ADR directory:

`docs/adr/`

Create an ADR index if useful:

`docs/adr/README.md`

Create the first ADR documenting the decision to use Architecture Decision Records.

Recommended filename:

`docs/adr/0001-use-architecture-decision-records.md`

The ADR should contain at least:

- Title
- Status
- Context
- Decision
- Consequences

Example:

```md
# ADR 0001: Use Architecture Decision Records

## Status

Accepted

## Context

The project needs a lightweight and persistent way to document important architectural and engineering decisions.

Decisions made only in conversations or agent contexts are easy to lose and difficult for future contributors or agents to reconstruct.

## Decision

We will use Architecture Decision Records stored in `docs/adr/`.

Important architectural decisions must be documented as ADRs.

ADRs should be concise and focused on decisions that materially affect the architecture, development workflow, dependencies, interfaces, or long-term maintainability of the project.

## Consequences

- Important decisions remain discoverable in the repository.
- Future developers and agents can understand why a decision was made.
- Architectural changes may require creating a new ADR rather than silently rewriting historical decisions.
- ADR documentation becomes part of the normal development workflow.
```

Commit separately.

Example:

`docs(adr): adopt architecture decision records`

After creating the initial ADR, surface it to the user for review.

---

# AGENTS.md

Create or update:

`AGENTS.md`

This file contains persistent repository-level instructions for coding agents.

Do not remove useful existing instructions.

Document the following permanent rules.

## Language

All development artifacts must be written in English.

This includes:

- source code;
- identifiers;
- comments;
- documentation;
- README files;
- ADRs;
- commit messages;
- tests;
- agent instructions;
- developer-facing error messages where appropriate.

Do not introduce non-English development documentation unless explicitly requested.

## Code Quality

Code must be:

- readable;
- modular;
- easy to understand;
- easy to modify;
- appropriately separated by responsibility.

Prefer straightforward solutions over unnecessary abstraction.

## Minimal Changes

Always make the smallest change necessary to complete the current task correctly.

Do not:

- perform unrelated refactors;
- rename unrelated files;
- reformat unrelated code;
- change public APIs unnecessarily;
- introduce dependencies without a clear reason;
- modify unrelated behavior.

Respect the existing architecture unless there is a documented reason to change it.

## ADR Rules

Before implementing a significant architectural decision:

1. Inspect existing ADRs.
2. Determine whether the decision is already documented.
3. Create a new ADR when a meaningful new architectural decision is introduced.
4. Never silently rewrite historical ADR decisions.
5. Supersede old ADRs with new ADRs when architectural decisions change.

Agents should treat `docs/adr/` as persistent architectural memory for the repository.

## Incremental Development

Work in small steps.

Prefer:

`inspect → plan → implement → validate → commit → report`

Each commit should represent one understandable unit of work.

---

# Caveman / README / Agents Review

After the initial repository structure is prepared, run the relevant repository-review skills when available:

1. Caveman
2. README review
3. Agents / AGENTS.md review

Use these reviews to find unnecessary complexity, unclear documentation, poor repository instructions, or violations of the project's development rules.

Apply only justified changes.

Do not blindly implement every suggestion produced by another skill or subagent.

Any changes resulting from these reviews must still follow:

- minimal-change rules;
- English-only development;
- modular/readable code;
- small commits;
- ADR rules.

Store the persistent rules discovered during this initialization in `AGENTS.md` so future agents automatically follow them.

---

# Development Workflow After Initialization

After initialization, continue implementing requested functionality one task at a time.

For every task:

1. Inspect the relevant repository state.
2. Check `AGENTS.md`.
3. Check relevant ADRs.
4. Delegate implementation/research to an appropriate subagent when supported.
5. Give the subagent only the context it needs.
6. Implement the smallest correct change.
7. Validate the result.
8. Create a small focused commit.
9. Push the completed commit when appropriate.
10. Report the result to the user.
11. Continue with the next task.

Avoid batching many unrelated tasks into one agent run or one commit.

---

# User Status Updates

After each completed unit of work, send the user a concise status update.

Example:

`✅ README initialized`

`Commit: docs(readme): describe project purpose`

`Pushed to main.`

Then continue with the next unit of work.

For work awaiting user review:

`🟡 agent.cmd created`

`Commit: docs(agent): define agent development workflow`

`Ready for your review.`

For the ADR:

`🟡 ADR 0001 created: Use Architecture Decision Records`

`docs/adr/0001-use-architecture-decision-records.md`

`Ready for your review.`

Do not hide several completed steps behind one final status message.

---

# General Constraints

Always:

- use English for code and development documentation;
- prefer minimal changes;
- write readable and modular code;
- inspect existing code before changing it;
- preserve useful existing repository conventions;
- use small commits;
- use meaningful Conventional Commit messages;
- consult ADRs before architectural changes;
- update or create ADRs when necessary;
- use subagents for implementation work when supported;
- validate subagent output before committing it;
- report progress after each completed task.

Never treat repository initialization as permission to rewrite the project unnecessarily.

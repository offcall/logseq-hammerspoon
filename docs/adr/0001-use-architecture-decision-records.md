# ADR 0001: Use Architecture Decision Records

## Status

Accepted

## Context

The project needs a lightweight and persistent way to document important
architectural and engineering decisions.

Decisions made only in conversations or agent contexts are easy to lose and
difficult for future contributors or agents to reconstruct.

## Decision

We will use Architecture Decision Records stored in `docs/adr/`.

Important architectural decisions must be documented as ADRs.

ADRs should be concise and focused on decisions that materially affect the
architecture, development workflow, dependencies, interfaces, or long-term
maintainability of the project.

ADRs are numbered sequentially (`NNNN-short-title.md`) and listed in
`docs/adr/README.md`.

## Consequences

- Important decisions remain discoverable in the repository.
- Future developers and agents can understand why a decision was made.
- Architectural changes require a new ADR that supersedes the old one rather than
  silently rewriting historical decisions.
- ADR documentation becomes part of the normal development workflow.

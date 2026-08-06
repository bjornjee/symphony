# ADR 008: Explicit multi-repository Team Mode

## Context
Some approved Linear requests require separate changes and PRs in multiple repositories. Repository selection crosses repository and worker trust boundaries, while the existing runner and its proof gates are intentionally single-repository.

## Decision
Symphony activates Team Mode only when `codex-ready`, `codex-team`, and a valid `## Team` section are present together. Ticket YAML names two to eight workflows but cannot supply repository URLs, hooks, commands, or credentials; workflow bootstrap derives a trusted repository registry from `workflow-manifest.yml` and embeds only workspace and hook configuration.

A request-local `TeamRunner` reserves `min(repository_count, max_concurrent_agents)` slots, creates one isolated workspace and top-level thread per repository, and reuses `AgentRunner` through narrow injection seams. A resumable coordinator thread emits validated sequential waves, running members only within a wave and never concurrently with the coordinator. A bounded in-memory event bus routes at most 100 four-kilobyte messages through the owning app-server process. Each repository produces its own PR; there is no cross-repository transaction.

Completion requires every member's fresh proof and PR plus a passing global coordinator verdict. Symphony maintains one idempotent Linear execution comment and exposes additive Team state through the existing API and dashboard. Thread identities persist in deterministic workspaces; after restart the explicit contract reconstructs agent identity and normal evidence validation runs again.

## Consequences
Ordinary `codex-ready` issues remain on `AgentRunner`. Team state is bounded and process-local, while durable thread and Git/PR evidence stay in repository workspaces and external systems. Removing `codex-team` or changing the approved contract stops execution at the next wave boundary. Operators must provision every declared repository for the same worker and Git/GitHub credentials.

## Rollback
Remove `codex-ready` from active Team issues and wait for their current wave boundary before reverting to a version that does not understand Team Mode. Existing workspaces, threads, branches, and PRs are retained and require no data migration.

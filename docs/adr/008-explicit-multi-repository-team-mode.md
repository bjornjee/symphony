# ADR 008: Explicit multi-repository Team Mode

## Context
Some approved Linear requests require separate changes and PRs in multiple repositories. Repository selection crosses repository and worker trust boundaries, while the existing runner and its proof gates are intentionally single-repository.

## Decision
Symphony activates Team Mode only when `codex-ready`, `codex-team`, and a valid `## Team` section are present together. Ticket YAML names two to eight workflows and explicit owned paths but cannot supply repository URLs, identities, hooks, commands, or credentials; workflow bootstrap derives a trusted repository registry from `workflow-manifest.yml` and embeds workspace and hook configuration plus a non-secret canonical repository identity.

A request-local `TeamRunner` reserves `min(repository_count, max_concurrent_agents)` slots, creates one isolated workspace and top-level thread per entry, and reuses `AgentRunner` through narrow injection seams. Entries for the same trusted repository must have mutually exclusive path ownership, and the synthetic member authorization excludes every other path. Synthetic member identifiers include the workflow alias so workspace and branch identities cannot collide after title truncation. A resumable coordinator thread emits validated sequential waves, running members only within a wave and never concurrently with the coordinator. A bounded in-memory event bus routes at most 100 four-kilobyte messages through the owning app-server process. Each entry produces its own PR; there is no cross-repository transaction.

Completion requires every member's fresh proof and PR plus a passing global coordinator verdict. Symphony maintains one idempotent Linear execution comment and exposes additive Team state through the existing API and dashboard. Thread identities persist in deterministic workspaces; after restart the explicit contract reconstructs agent identity and normal evidence validation runs again.

## Consequences
Ordinary `codex-ready` issues remain on `AgentRunner`. Team state is bounded and process-local, while durable thread and Git/PR evidence stay in repository workspaces and external systems. Removing `codex-team` or changing the approved contract stops execution at the next wave boundary. Operators must provision every declared workflow and Git push credentials on its worker; Symphony runs `gh` API operations on the controller, where GitHub API credentials remain. Same-repository aliases use separate workspace roots, branches, and the same canonical repository identity. A native Codex goal that becomes blocked while completion evidence is missing terminates in Human Review instead of being automatically resumed.

## Rollback
Remove `codex-ready` from active Team issues and wait for their current wave boundary before reverting to a version that does not understand Team Mode. Existing workspaces, threads, branches, and PRs are retained and require no data migration.

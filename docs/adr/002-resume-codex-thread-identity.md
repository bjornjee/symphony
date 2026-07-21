# ADR 002: Resume one durable Codex thread

## Context
Worker and Symphony process retries preserve issue workspaces but previously started replacement
Codex threads, losing the canonical conversation and goal state.

## Decision
Symphony exclusively creates `.symphony/codex-thread.json` with schema version 1 and the canonical
thread id after `thread/start`. Later attempts read that one-workspace artifact and call the Codex
app-server `thread/resume` method with the exact id. Missing or rejected Codex history, malformed
artifacts, and identity conflicts fail the attempt without creating a replacement. Goal status maps
active and retryable outcomes to `active`, input-required outcomes to `blocked`, and non-active,
non-routable, or terminal handoffs to `complete`.

## Consequences
One Linear issue workspace has one durable Codex conversation across worker and process retries,
including SSH workspaces. The artifact is additive and create-only, while PIN-14's execution
manifest and plan digest remain immutable. Rollback is a code revert: older code ignores the
artifact; no data migration or deletion is required.

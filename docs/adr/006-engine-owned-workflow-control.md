# ADR 006: Engine-owned workflow control

## Context
Agent-authored proof mappings and publication commands can claim success without binding evidence to the approved authority or final repository state.

## Decision
Symphony hashes explicit, well-formed Codex-reported instruction sources with the contract, workflow profile, thread, and repository identity. Approved plans use typed proof contracts. Symphony executes proofs through sandboxed app-server `command/exec`, persists immutable receipts outside the agent workspace, gates phase completion, and owns review and PR publication boundaries. Linear handoff re-reads the published PR and verifies its open state, repository, head, head branch, and base branch.

## Consequences
Implementation turns have workspace write access without network access. Proofs have no unsandboxed fallback: they receive workspace-scoped writes, disabled network, a scrubbed credential environment, connection-owned process lifetime, and bounds of three attempts, thirty minutes, and one MiB of output. Instruction or repository drift fails closed; clean final proof and review receipts become stale after any edit or commit. PR state can invalidate handoff after publication. The control store is single-instance local state and is deliberately not a cross-host coordination protocol.

## Rollback
Restore the previous goal-first runner and Symphony-owned profiles; stop reading the external control store after confirming no active issue references it.

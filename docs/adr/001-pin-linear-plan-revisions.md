# ADR 001: Pin Linear plan revisions

## Context
Linear issue title and description are external inputs that can change while Codex is running.

## Decision
Symphony deterministically validates `Codex Agent Task v1` before claim or workspace mutation.
It hashes canonical title and description and atomically pins that digest in the issue workspace.
Every continuation compares the refreshed issue with the pinned digest; drift stops execution.

## Consequences
Approved plans become immutable for one execution, while `updatedAt` remains provenance only.
The first slice preserves the existing retry model; durable thread recovery and reapproval are later slices.
Rollback is a code revert; manifests are additive and require no migration.

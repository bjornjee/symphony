# ADR 003: Publish idempotent Linear handoffs

Amended by ADR 006: the validated artifact identity now comes from immutable external execution receipts.

## Context

Completed-work handoff comments and workflow state are externally visible writes. Engine-owned
writes can duplicate after retries, restarts, concurrent attempts, or ambiguous network outcomes.

## Decision

Symphony alone renders and publishes `## Agent Handoff` after PIN-16 validation. It hashes issue ID,
pinned plan digest, and the validated semantic artifact identity (criterion set plus PR URL) into a
marker and caller-supplied UUIDv4 Linear comment ID. Immutable proof-receipt digests remain validation
inputs but are excluded from external identity and output, so a proof rerun converges. Symphony reads
the exact comment under the current issue with `first: 1`, creates when absent, always reads back,
and only then updates configured `tracker.handoff_state`.

## Consequences

Retries and concurrent creates converge on one Linear identity; mismatched bodies fail closed.
Rendered output includes only PR URL, pinned criteria with pass status, summary, and human action.
Rollback is a code/config revert; published comments remain visible and require no data migration.

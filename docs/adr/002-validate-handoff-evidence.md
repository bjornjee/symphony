# ADR 002: Validate durable handoff evidence

## Context

PIN-14 pins an issue plan, but tracker state and agent prose cannot prove that each criterion passed
or that a repository pull request exists.

## Decision

Use `.symphony/completion-evidence.json` v1, tied to the pinned plan digest and stable criterion IDs.
The agent atomically replaces the envelope after proof and PR creation. Symphony validates exact
criterion coverage, current-run engine-observed successful command event IDs, and a repository-
matching GitHub PR URL resolved through `gh pr view` before accepting handoff. Engine memory, not
editable audit JSON, is the proof authority. Validation is bounded to 100 criteria, 256 command
proofs, a 128 KiB artifact, and one repository-host lookup.

## Consequences

Handoffs fail closed with explicit reasons when evidence is absent, stale, malformed, forged,
partial, duplicated, or points outside the repository. Older PIN-14 manifests remain readable, and
failed attempts may idempotently replace the envelope. Cross-run proof durability can later be
integrated with PIN-15 without changing v1 criterion or PR fields. Reverting this change removes the
handoff validator and additive manifest metadata; no migration, deletion, or Linear mutation is
required.

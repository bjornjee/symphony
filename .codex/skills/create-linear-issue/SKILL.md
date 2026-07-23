---
name: create-linear-issue
description: Create one Linear issue from a Codex Agent Task v1 contract, validate its destination, verify the created issue by readback, and optionally dispatch it. Use when a user explicitly asks Codex to create a new Linear issue or create and dispatch one for Symphony.
---

# Create Linear Issue

Create one verified Linear issue per invocation. Keep orchestration here and use
the repository's `.codex/skills/linear/SKILL.md` for all raw `linear_graphql`
queries and mutations.

## Authority

- An explicit create request is sufficient mutation authority. Do not ask for
  confirmation before creating the issue.
- Ask for input only when a materially ambiguous field remains after bounded
  read-only resolution. Do not guess between zero matches or multiple matches.
- Treat issue creation and dispatch as separate decisions. A request to create
  does not authorize dispatch.
- Produce one resulting issue. Do not perform general triage, lifecycle
  management, or destination-object creation.

## Task contract

Render the description in this exact order. Omit `Notes For Agent` only when it
has no content; when present, keep it last.

```md
## Goal
<one concrete outcome>

## Context
<project-specific facts and links>

## Scope
In:
- <files, components, or systems the agent may change>

Out:
- <explicit non-goals>

## Acceptance Criteria
- [ ] <observable result>

## Verification
Run:
`<exact command, or "agent selects smallest sufficient proof">`

## Risk
<low | medium | high>

## Notes For Agent
<optional constraints and an exact Workflow line when needed>
```

Replace every placeholder with concrete content. Apply the semantics in
`docs/codex-agent-task-contract.md`: require one outcome, project-specific
context, non-empty `Scope.In` and `Scope.Out` lists, unique observable
checkboxes, a verification instruction, and a `low`, `medium`, or `high` risk.
Reject empty, duplicate, out-of-order, placeholder, or malformed sections
before `issueCreate`.

## Workflow

### 1. Normalize the request

Collect the title, complete task description, target team, project, state,
requested labels, and whether dispatch was explicitly requested. Preserve a
canonical copy of every expected value for readback comparison.

Do not request redundant input. Continue when each field is already explicit or
has exactly one valid resolution. Ask one narrow question only for a materially
ambiguous field.

### 2. Validate the contract

Validate the title and rendered description against Codex Agent Task v1 before
any mutation. Stop with the actionable validation error when the contract is
malformed. Do not create an issue that would fail Symphony's dispatch parser.

### 3. Resolve the destination

Use the target-resolution operations in `.codex/skills/linear/SKILL.md`.
Resolve the team first, then resolve the project, workflow state, and labels in
that team's scope. If dispatch was explicitly requested, also resolve the
existing `codex-ready` label, but keep it out of the create input.

Require exactly one compatible match for the team, project, state, and every
requested label before any mutation:

- On zero matches, request a corrected value.
- On multiple matches, request the exact selection.
- Reject a project, state, or label that does not belong to the resolved team.
- Never create a team, project, workflow state, or label.

### 4. Create once

Call `linear_graphql` with the `CreateIssue` operation from the `linear` skill.
Pass the validated `teamId`, `projectId`, `stateId`, title, description, and the
resolved non-dispatch `labelIds`.

Treat a top-level `errors` array, `success: false`, or a definitive validation
error as failure even when the tool call itself completed. A successful response
must contain the new issue id and identifier.

### 5. Reconcile uncertainty

An ambiguous create response is a transport interruption, timeout, or incomplete
payload where the mutation outcome is unknown. Perform read-only reconciliation
with `ReconcileIssueCreate` before retry:

- Compare the canonical title and description plus team, project, state, and
  non-dispatch labels within the bounded invocation window.
- If exactly one full match exists, treat it as the created issue and continue.
- If zero, multiple, or partial matches exist, stop and report the ambiguity.
  A zero-result read cannot prove absence immediately after an uncertain write.
- Before any later explicit retry, repeat read-only reconciliation and proceed
  only when the prior outcome is no longer ambiguous.

Do not blindly retry or automatically repeat `issueCreate`. The invocation must
finish with at most one resulting issue.

### 6. Verify by readback

Read the issue back by internal id with `IssueCreationReadback`. Compare the
exact canonical title and description and the resolved team, project, state,
and complete non-dispatch labels. Treat any mismatch or missing field as a
failure; report expected and actual values without claiming success.

### 7. Optionally dispatch

`codex-ready` is never implicit. Add it only when dispatch was explicitly
requested, the contract validates, destination resolution succeeded, and the
initial readback matched.

Use the resolved full label-id union in a separate `issueUpdate` through the
`AddIssueLabels` operation so existing labels are preserved. Read the issue back
again and verify `codex-ready` is present before reporting dispatch success.

### 8. Report the result

Return the identifier and URL, whether the issue was recovered through
reconciliation, the verified destination and labels, and whether dispatch was
performed. Report one failure clearly and stop; do not create compensating
issues.

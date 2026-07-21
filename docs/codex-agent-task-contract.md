# Codex Agent Task v1

Use this exact issue shape for work Symphony may dispatch to Codex.

```md
## Goal
<one concrete outcome>

## Context
<links to repo, PRs, docs, Slack thread, screenshots, logs, or prior issues>

## Scope
In:
- <files/components/systems the agent may change>

Out:
- <explicit non-goals>

## Acceptance Criteria
- [ ] <observable result>
- [ ] <observable result>

## Verification
Run:
`<exact command, or "agent selects smallest sufficient proof">`

## Risk
<low | medium | high>

## Notes For Agent
<optional constraints, `Use agent-dashboard:<workflow>`, or known pitfalls>
```

## Semantics

- `Goal`, `Context`, `Scope`, `Acceptance Criteria`, `Verification`, and `Risk`
  are required, in that order. `Goal` must describe one outcome.
- `Context` holds project-specific facts: repository, Linear project, PRs,
  Slack threads, docs, logs, screenshots, or prior issues.
- `Scope.In` and `Scope.Out` each require at least one bullet so execution and
  adjacent non-goals are explicit.
- `Acceptance Criteria` must be observable checklist items.
- `Verification` is required. If unknown, write `agent selects smallest
  sufficient proof`.
- `Risk` is required and should be `low`, `medium`, or `high`.
- `Notes For Agent` is optional.
- Use `Notes For Agent` for deterministic workflow routing. When an issue says
  `Use agent-dashboard:<workflow>`, Symphony prepends
  `$agent-dashboard:<workflow>` before handing the prompt to Codex.

Symphony validates this shape before changing the claim state, creating a
workspace, running a hook, or starting Codex. Empty, duplicate, out-of-order,
placeholder, or malformed sections block dispatch with an actionable log. The
issue must be corrected and approved again; an agent is never started to repair
its own execution contract.

For every valid dispatch, Symphony computes a versioned SHA-256 digest from the
canonical title and description. Line-ending and trailing-whitespace differences
are normalized; `updatedAt` is provenance only. The first attempt atomically
writes `.symphony/execution-manifest.json`. Later attempts must match its issue
identity and plan digest. A changed title or description stops before another
Codex turn and never overwrites the pinned revision.

Each acceptance criterion also receives a stable `ac-<sha256>` identity derived
from its canonical text. Checkbox state does not affect that identity, and
duplicate criterion text is rejected. New execution manifests include the
criterion identities and text; the rendered agent prompt also includes them so
workspaces first pinned by older manifests remain actionable.

## Dispatch Rule

Only add `codex-ready` when the issue is safe to dispatch. Project identity
belongs in the Linear project, issue context, repository URL, and workflow
manifest, not in a different issue contract.

When `tracker.claim_state` is configured, Symphony moves a dispatchable issue to
that state before starting Codex. The production workflows use `In Progress` so
Linear reflects the handoff immediately.

## Agent Execution

Symphony owns scheduling. The selected `agent-dashboard:*` workflow owns how
the agent works inside the repository.

Agents must:

- select the smallest matching `agent-dashboard` workflow before editing
- follow that workflow's branch, worktree, environment setup, planning, proof,
  commit, PR, and cleanup gates exactly
- use isolated git worktrees for `feature`, `fix`, and `refactor` work
- copy and validate `.env*` files when the selected workflow's worktree setup
  requires it
- run environment setup through the selected workflow's sentinel rules
- avoid replacing workflow gates with ad hoc prompt reasoning
- atomically write `.symphony/completion-evidence.json` v1 before requesting
  human handoff
- map every pinned criterion identity exactly once to an engine-observed,
  successful command proof event from the current run
- include an HTTPS GitHub pull request URL for the workspace's `origin`
  repository

Symphony validates the completion envelope after a normal Codex turn and before
accepting a handoff transition. Free-form proof, issue checkbox state, edited
audit JSON, agent-supplied exit codes, stale plan digests, partial or duplicate
criterion coverage, and non-PR or cross-repository URLs fail closed. The audit
file exposes proof event IDs for the agent and reviewer, while the in-memory
engine ledger remains authoritative for validation. Symphony also resolves the
candidate URL with `gh pr view`; a syntactically valid but missing or inaccessible
PR is not accepted.

If the required workflow setup cannot be completed, stop and post one
`## Agent Blocked` comment with the missing prerequisite and requested human
action.

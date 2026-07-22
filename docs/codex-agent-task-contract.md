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
<optional constraints, exact `Workflow: feature|fix|refactor|chore|pr`, or known pitfalls>
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
- Use `Notes For Agent` for deterministic workflow routing with one exact
  `Workflow: feature|fix|refactor|chore|pr` line. Without it, Symphony falls
  back to a conventional title prefix and otherwise fails closed.

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

Symphony owns scheduling, preactivation classification and review, and the
selected built-in workflow profile.

Before preactivation planning, Symphony classifies the pinned contract. A
low-risk `feature`, `fix`, `refactor`, or `chore` may execute directly only when
its conventional title matches the workflow, `Scope.In` names one path, there
is one acceptance criterion, `Verification` contains one exact backtick-delimited
command, and no risky or decomposition signal is present.
All other tasks receive native planning and medium-effort automated review.
`Planning: full` in `Notes For Agent` always selects the reviewed path.

Agents must:

- execute the approved execution authorization sealed before goal activation
- for planned tasks, execute typed phases in order, satisfy only prior-phase dependencies, and keep
  exactly one native-plan phase in progress
- for simple tasks, remain within the one approved path and proof command without manufacturing
  native-plan phases
- for planned tasks, mark a phase completed only after its proof and evidence requirements pass;
  handoff requires an exact all-completed native plan
- reuse Symphony's issue workspace and never create a nested worktree
- create or resume one task branch from the pinned base after goal activation
- follow the selected profile's proof, review, commit, and PR gates
- avoid replacing workflow gates with ad hoc prompt reasoning
- atomically write `.symphony/completion-evidence.json` v2 before requesting
  human handoff
- map every pinned criterion identity exactly once to an engine-observed,
  successful command proof event from the current run
- include an HTTPS GitHub pull request URL for the workspace's `origin`
  repository
- bind workflow-specific proof and the final reviewed local/PR head SHA
- do not create the completed-work Linear handoff comment or move the issue;
  Symphony owns those writes after evidence validation

Symphony validates the completion envelope after a normal Codex turn, renders
one deterministic semantic handoff, reads it back, and only then performs the
configured handoff transition. Free-form proof, issue checkbox state, edited
audit JSON, agent-supplied exit codes, stale plan digests, partial or duplicate
criterion coverage, and non-PR or cross-repository URLs fail closed. The audit
file exposes proof event IDs for the agent and reviewer, while the in-memory
engine ledger remains authoritative for validation. Symphony also resolves the
candidate URL with `gh pr view`; a syntactically valid but missing or inaccessible
PR is not accepted.

If the required workflow setup cannot be completed, preserve the concrete failure evidence and
stop. Symphony owns tracker publication and routing for blocked work.

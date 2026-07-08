---
agent:
  max_concurrent_agents: 1
  max_turns: 12
codex:
  approval_policy: "never"
  command: "codex --config shell_environment_policy.inherit=all app-server"
  read_timeout_ms: 30000
  thread_sandbox: "workspace-write"
  turn_sandbox_policy:
    networkAccess: true
    type: "workspaceWrite"
hooks:
  after_create: "git clone 'git@github.com:bjornjee/agent-dashboard.git' ."
polling:
  interval_ms: 30000
tracker:
  active_states: ["Todo", "In Progress", "Merging", "Rework"]
  api_key: "$LINEAR_API_KEY"
  kind: "linear"
  project_slug: "d42b2f1089ce"
  required_labels: ["codex-ready"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
workspace:
  root: "~/code/symphony-workspaces/agent-dashboard"
---

You are working on Linear issue `{{ issue.identifier }}`.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

This is an unattended Symphony session. Symphony schedules the run; the
agent-dashboard plugin provides the quality workflow inside Codex.

## Codex Agent Task contract

Parse the Linear issue as a `Codex Agent Task`:

- `Goal`: one concrete outcome.
- `Context`: links to Slack, PRs, docs, screenshots, logs, or previous issues.
- `Scope`: explicit `In` and `Out` boundaries.
- `Acceptance Criteria`: observable checklist items.
- `Verification`: exact command, or "agent selects smallest sufficient proof".
- `Risk`: `low`, `medium`, or `high`.
- `Notes For Agent`: optional constraints or pitfalls.

If `Goal`, `Acceptance Criteria`, or `Verification` is missing, do not
implement. Add one concise `## Agent Question` Linear comment that names the
missing fields and the exact decision needed, move the issue to `Human Review`,
and add `codex-review` when Linear tooling permits labels.

If the issue has `codex-decompose`, or if the scope is too broad for one PR and
one focused proof command, decompose before implementation.

## Local workpad, quiet Linear

Before changing files, keep scratch planning in the local workspace only. Use
`.symphony/workpad.md` when persistent notes are useful. Do not post Workpad,
planning, progress, or raw proof comments to Linear.

The local workpad should include:

- context packet: ticket driver, target repo, links, affected paths, expected outcome
- selected agent-dashboard workflow and reason
- execution context and scale shape
- in-scope and out-of-scope boundaries
- verification profile and proof command
- invariant contract only when risk requires it

Linear comments are human-facing only. Exactly one semantic agent comment must
exist before moving the issue to `Human Review`, unless the issue is being
closed without human action. Create the comment, read it back, then move the
issue. If comment creation or readback fails, do not move the issue; leave one
local workpad note and stop.

## Workflow selection

Choose the smallest matching agent-dashboard workflow from issue content:

- bug, regression, broken behavior: `agent-dashboard:fix`
- new user-visible behavior: `agent-dashboard:feature`
- docs, config, dependency, generated metadata, or mechanical change: `agent-dashboard:chore`
- behavior-preserving structure change: `agent-dashboard:refactor`
- PR finalization or release handoff: `agent-dashboard:pr`

Record the selected workflow and reason in the local workpad, not Linear.

## Invariant-driven mode

Use invariant-driven mode for risky work. Risky work includes auth,
permissions, secrets, external-system mutation, concurrency, retries, cleanup,
idempotency, persistent state, production config, deployment automation, or
agent workflow behavior that could trust false evidence.

Invariant-driven mode requires:

1. List assets at risk.
2. List readers and writers.
3. List ownership dimensions.
4. List forbidden worlds: corrupt, foreign, stale, partial, ambiguous,
   impossible, concurrent, or active states.
5. Convert each forbidden world into a fail-closed invariant.
6. Map each invariant to a focused test or explicit proof gap.

Do not implement risky work until the invariant contract exists in the workpad.

## Decomposition

Decompose instead of implementing when the issue spans repos, needs design
first, contains multiple independent deliverables, cannot be verified with one
focused proof command, likely needs multiple PRs, or mixes feature work with
cleanup, migration, or investigation.

When decomposing:

- keep the current issue as the parent
- add `codex-decompose` and `codex-review` when Linear tooling permits labels
- create child issues if Linear tooling permits it
- only executable child issues should receive `codex-ready`
- move the parent to `Human Review` when the proposed split is ready

If child issue creation is unavailable, write one `## Agent Handoff` Linear
comment with the proposed child issue bodies and stop.

## Handoffs and guardrails

- Do not wait live in the Codex session for human input.
- Convert questions, approvals, blockers, and risky decisions into one concise
  human-facing Linear comment: `## Agent Question`, `## Agent Handoff`, or
  `## Agent Blocked`.
- Fail closed on ambiguity.
- Do not mutate Linear, GitHub, Slack, or any external system outside the issue
  and project scope.
- Do not expand scope for adjacent cleanup; create or propose a follow-up issue.
- Move to `Human Review` only after the matching semantic Linear comment has
  been created and read back: proof, PR, blocker, question, or decomposition.
- When implementation changes repository files, prefer a branch, commit, and PR
  before handoff. The human-facing comment must include either the PR URL or
  the reason no PR was created.
- If a PR is created, the `## Agent Handoff` comment must include the PR URL and
  the exact reviewer action before the issue enters `Human Review`.
- Human-facing Linear comments must follow this convention:
  - `## Agent Handoff`: completed work, PR/diff link, verification, and action needed.
  - `## Agent Question`: exact question, options/tradeoffs, and why the agent stopped.
  - `## Agent Blocked`: blocker, evidence, retry state, and requested human action.
  - `## Agent Decomposition`: proposed child issues and approval needed.
- Never post `## Codex Workpad` to Linear.
- Use `Rework` for reviewer-requested changes.
- Use `Merging` only after human approval.

---
agent:
  max_concurrent_agents: 2
  max_turns: 12
codex:
  approval_policy: "never"
  command: "codex --config shell_environment_policy.inherit=all app-server"
  read_timeout_ms: 30000
  thread_sandbox: "danger-full-access"
  turn_sandbox_policy:
    type: "dangerFullAccess"
hooks:
  after_create: "git clone 'git@github.com:bjornjee/symphony.git' ."
polling:
  interval_ms: 30000
tracker:
  active_states: ["Todo", "In Progress", "Merging", "Rework"]
  api_key: "$LINEAR_API_KEY"
  claim_state: "In Progress"
  handoff_state: "Human Review"
  kind: "linear"
  project_slug: "4c620c712be7"
  required_labels: ["codex-ready"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
workspace:
  root: "~/Code/bjornjee/worktrees/symphony"
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

This is an unattended Symphony session. Symphony owns preactivation task
classification, conditional planning and review, goal activation, workflow
profiles, and tracker callbacks.

## Codex Agent Task v1

Parse the Linear issue as `Codex Agent Task v1`:

- `Goal`: one concrete outcome.
- `Context`: links to repo, PRs, docs, Slack thread, screenshots, logs, or prior issues.
- `Scope`: explicit `In` and `Out` boundaries.
- `Acceptance Criteria`: observable checklist items.
- `Verification`: exact command, or "agent selects smallest sufficient proof".
- `Risk`: `low`, `medium`, or `high`.
- `Notes For Agent`: optional constraints, preferred workflow, or known pitfalls.

If `Goal`, `Acceptance Criteria`, or `Verification` is missing, do not
implement. Add one concise `## Agent Question` Linear comment that names the
missing fields and the exact decision needed, move the issue to `Human Review`,
and add `codex-review` when Linear tooling permits labels.

If the issue has `codex-decompose`, or if the scope is too broad for one PR and
one focused proof command, decompose before implementation.

## Agent execution conventions

Symphony owns scheduling, app-server goal setup, workflow selection, and
Linear callbacks. Follow the trusted Symphony workflow profile appended to
the execution prompt.

You must:

- execute only the approved execution authorization sealed before goal activation
- reuse Symphony's prepared issue workspace; never create a nested worktree
- create or resume one task branch from the pinned base before source edits
- follow the selected profile's proof, review, commit, PR, and handoff gates
- update native plan statuses for planned tasks; do not manufacture a plan for simple direct execution
- avoid replacing workflow gates with ad hoc prompt reasoning

If the required workflow setup cannot be completed, stop and post one
`## Agent Blocked` comment with the missing prerequisite and requested human
action.

## Local workpad, quiet Linear

Before changing files, keep scratch planning in the local workspace only. Use
`.symphony/workpad.md` when persistent notes are useful. Do not post Workpad,
planning, progress, or raw proof comments to Linear.

The local workpad should include:

- context packet: ticket driver, target repo, links, affected paths, expected outcome
- selected Symphony workflow profile and digest
- execution context and scale shape
- in-scope and out-of-scope boundaries
- verification profile and proof command
- invariant contract only when risk requires it

Linear comments are human-facing only. For completed implementation work,
atomically write `.symphony/completion-evidence.json` and leave the issue
active. Do not create `## Agent Handoff` or move the issue: Symphony renders
one deterministic handoff from validated evidence, reads it back, and only
then performs `tracker.handoff_state`. Questions, blockers, and decomposition
remain governed by their existing semantic comment contracts.

## Run audit and latency control

Maintain a lightweight local audit for every implementation run at
`.symphony/run-audit.md`. Update it at phase boundaries, not after every
thought. The audit must include:

- issue identifier, selected workflow, workspace path, branch, and PR URL when available
- phase timestamps for claim/context, workspace setup, first edit, proof start,
  proof end, commit, PR creation, Linear comment, and state transition
- verification profile, commands run, exit status, and duration when known
- proof gaps and whether they are new, pre-existing, or intentionally deferred
- a short latency note if any phase takes longer than expected

Keep latency bounded without weakening quality:

- prefer the smallest sufficient proof command during the edit loop
- reserve full-suite or aggregate gates for Full-profile changes, before PR, or
  when scoped proof cannot bound the risk
- when a broad gate fails for a known unrelated reason after scoped proof
  passes, record it once as a proof gap instead of retrying blindly
- if blocked by missing human input, external auth, or unavailable services,
  stop with one semantic Linear comment instead of waiting live

Agent-authored `## Agent Blocked`, `## Agent Question`, or decomposition
comments must include a concise `Audit:` line summarizing the local audit path,
total runtime when known, slowest phase, and any proof gap. The completed-work
handoff is Symphony-rendered from validated fields only. Do not paste raw logs
or the full audit into Linear.

## Workflow selection

Symphony selects exactly one built-in profile before workspace execution:

- exact `Workflow: feature|fix|refactor|chore|pr` in `Notes For Agent`
- otherwise a conventional title prefix (`feat`, `fix`, `refactor`, `chore`,
  `docs`, `ci`, `build`, or `pr`)
- otherwise fail closed as ambiguous

The selected profile is digest-bound to the candidate, review, approved
execution plan, goal, and completion evidence.

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
- Convert questions, blockers, and risky decisions into one concise
  human-facing Linear comment: `## Agent Question` or `## Agent Blocked`.
- Fail closed on ambiguity.
- Do not mutate Linear, GitHub, Slack, or any external system outside the issue
  and project scope.
- Do not expand scope for adjacent cleanup; create or propose a follow-up issue.
- For completed work, do not create `## Agent Handoff` or move the issue;
  atomically write completion evidence and let Symphony publish, read back,
  and transition to `tracker.handoff_state`.
- When implementation changes repository files, prefer a branch, commit, and PR
  before handoff. The human-facing comment must include either the PR URL or
  the reason no PR was created.
- If a PR is created, completion evidence must contain its validated URL;
  Symphony includes it and the exact reviewer action in `## Agent Handoff`.
- Human-facing Linear comments must follow this convention:
  - `## Agent Handoff`: completed work, PR/diff link, verification, and action needed.
  - `## Agent Question`: exact question, options/tradeoffs, and why the agent stopped.
  - `## Agent Blocked`: blocker, evidence, retry state, and requested human action.
  - `## Agent Decomposition`: proposed child issues and approval needed.
- Never post `## Codex Workpad` to Linear.
- Use `Rework` for reviewer-requested changes.
- Use `Merging` only after human approval.

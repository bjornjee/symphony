# Agent Dashboard Linear Setup

This guide describes the Linear shape for running Symphony against
`bjornjee/agent-dashboard`.

Symphony is the scheduler and runner. The `agent-dashboard` plugin is the
quality workflow used inside each Codex session.

## Project

Create one Linear project in the `pinkgu` workspace and agent workflow team:

`Agent Dashboard`

Use this project as the only dispatch surface for the first Symphony rollout.
Slack can notify or link to issues, but Linear remains the source of truth.

## Statuses

Configure these statuses for the project/team workflow:

- `Backlog`: captured but not eligible for Symphony.
- `Todo`: queued for Symphony when `codex-ready` is present.
- `In Progress`: active agent work.
- `Human Review`: plan, proof, PR, blocker, or decomposition needs review.
- `Rework`: reviewer requested changes; eligible for another agent pass.
- `Merging`: human approved; agent may run merge or land flow.
- `Done`: terminal complete.
- `Canceled` or `Cancelled`: terminal stopped.
- `Duplicate`: terminal duplicate.

The corresponding Symphony template uses these active states:

```yaml
active_states:
  - Todo
  - In Progress
  - Merging
  - Rework
```

## Labels

Keep labels minimal:

- `codex-ready`: the only required dispatch label.
- `codex-blocked`: missing input, access, secret, or decision.
- `codex-review`: plan, proof, PR, or decomposition needs human review.
- `codex-decompose`: issue should be split before implementation.
- `symphony`: marker for issues and PRs touched by Symphony.

Do not add workflow-type labels for v1. Codex chooses
`agent-dashboard:feature`, `agent-dashboard:fix`, `agent-dashboard:chore`,
`agent-dashboard:refactor`, or `agent-dashboard:pr` from issue content and
records the reason in the workpad.

Only `codex-ready` gates dispatch:

```yaml
required_labels:
  - codex-ready
```

The production workflows set `tracker.claim_state: In Progress`. Symphony moves
an issue from `Todo` to `In Progress` before starting Codex; if Linear cannot
acknowledge the state change, dispatch is retried instead of silently running
while the board still says queued.

## Issue Title Convention

Use semantic, action-oriented issue titles:

`<type>: <imperative outcome>`

Recommended types:

- `feat`: user-visible behavior or capability
- `fix`: bug, regression, or broken behavior
- `chore`: docs, config, setup, dependency, or mechanical change
- `refactor`: behavior-preserving structure change
- `test`: test-only work
- `ci`: CI or release automation

Examples:

- `chore: verify Symphony creates PR handoff`
- `feat: add Slack trigger intake for Codex tasks`
- `fix: prevent agents from reposting Workpad comments`

Linear issue identifiers use the Linear team key. Keep the team key short,
stable, and domain-specific; do not encode workflow state in the key.

## Codex Agent Task

Use `Codex Agent Task v1` from `docs/codex-agent-task-contract.md` for every
issue that Symphony may dispatch. Project-specific details for agent-dashboard
belong in `Context`, `Scope`, and `Notes For Agent`; the issue contract itself
must stay identical across Linear projects.

## Decomposition

Decompose before implementation when an issue:

- spans multiple repos
- requires architecture or design first
- contains multiple independent deliverables
- cannot be verified with one focused proof command
- likely needs more than one coherent PR
- mixes feature work with cleanup, migration, or investigation

Parent decomposition template:

```md
## Goal
Split this into executable Codex agent tasks.

## Context
<why this is larger than one PR or one proof command>

## Desired Children
- <child outcome>
- <child outcome>

## Constraints
<ordering, dependencies, repo boundaries, or review expectations>
```

Child issue template:

```md
## Goal
<one executable outcome>

## Context
Parent: <parent issue link>
<relevant notes copied from parent>

## Scope
In:
- <files/components>

Out:
- <non-goals>

## Acceptance Criteria
- [ ] ...

## Verification
Run:
`<command>`

## Dependencies
Blocked by: <issue or none>
```

When decomposition is required:

- keep the original issue as the parent
- add `codex-decompose` and `codex-review`
- create child issues if tooling is available
- put `codex-ready` only on executable child issues
- leave the parent in `Human Review` or otherwise out of active dispatch until
  children are complete

## Comment And Workpad Contract

Keep agent scratch notes local. Use `.symphony/workpad.md` inside the agent
workspace when persistent planning notes are useful. Do not post Workpad,
progress, or raw proof comments to Linear.

Linear comments are human-facing and semantic:

- `## Agent Handoff`: completed work, PR or diff link, verification, and exact human action needed.
- `## Agent Question`: blocking question, options/tradeoffs, and why the agent stopped.
- `## Agent Blocked`: blocker, evidence, retry state, and requested human action.
- `## Agent Decomposition`: proposed child issues and approval needed.

At Human Review, exactly one semantic agent comment should exist unless the
issue was closed without human action. The agent must create the comment, read
it back, and only then move the issue to `Human Review`. If readback fails, the
agent should not move the issue.

For implementation work, the `## Agent Handoff` comment must include either a
PR URL or a clear reason no PR was created, plus the exact reviewer action.

## Invariant-Driven Mode

Use invariant-driven mode only for risky work:

- auth, permissions, secrets, or credentials
- external-system mutation such as Linear, GitHub, or Slack writes
- concurrency, leases, retries, cleanup, idempotency, or recovery
- persistent state, migrations, production config, or deployment automation
- agent workflow behavior that could trust false evidence or mutate the wrong resource

Invariant-driven mode requires:

- assets at risk
- readers and writers
- ownership dimensions
- forbidden worlds
- fail-closed invariants
- focused tests or explicit proof gaps

Low-risk isolated edits should stay lightweight and use the normal
agent-dashboard verification profile.

## Operating Guardrails

- Fail closed on ambiguity.
- Do not wait live in Codex for human input.
- Convert questions, approvals, blockers, and risky decisions into one concise
  semantic Linear comment.
- Do not silently overwrite external state.
- Do not mutate Linear, GitHub, or Slack outside the issue/project scope.
- Do not expand scope; create or propose follow-up issues instead.
- Move to `Human Review` only after the matching semantic Linear comment has
  been created and read back for the plan, proof, PR, question, blocker, or
  decomposition.

## Running Symphony

`WORKFLOWS.yml` is the source of truth for production workflow setup. After
changing tracker, workspace, repository, or prompt settings, regenerate and
check the workflow output:

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
mise exec -- mix workflow.bootstrap --manifest ../WORKFLOWS.yml
mise exec -- mix workflow.bootstrap --manifest ../WORKFLOWS.yml --check
```

Run Symphony with the generated agent-dashboard workflow:

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
export LINEAR_API_KEY=...
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  /Users/bjornjee/Code/bjornjee/symphony/workflows/agent-dashboard/WORKFLOW.md
```

The dashboard is available on the selected port when `--port` is provided.

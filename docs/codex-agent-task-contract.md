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
<optional constraints, preferred workflow, or known pitfalls>
```

## Semantics

- `Goal` is required and must describe one outcome.
- `Context` holds project-specific facts: repository, Linear project, PRs,
  Slack threads, docs, logs, screenshots, or prior issues.
- `Scope.In` is required when code or docs may be changed.
- `Scope.Out` is required when adjacent cleanup or expansion is plausible.
- `Acceptance Criteria` must be observable checklist items.
- `Verification` is required. If unknown, write `agent selects smallest
  sufficient proof`.
- `Risk` is required and should be `low`, `medium`, or `high`.
- `Notes For Agent` is optional.

If `Goal`, `Acceptance Criteria`, or `Verification` is missing, the agent must
not implement. It should post one `## Agent Question` comment that asks for the
missing decision and move the issue to `Human Review`.

## Dispatch Rule

Only add `codex-ready` when the issue is safe to dispatch. Project identity
belongs in the Linear project, issue context, repository URL, and workflow
manifest, not in a different issue contract.

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

If the required workflow setup cannot be completed, stop and post one
`## Agent Blocked` comment with the missing prerequisite and requested human
action.

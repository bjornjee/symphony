# Symphony Linear Setup

This project dogfoods Symphony against `bjornjee/symphony`.

Linear project:

- Name: `Symphony`
- URL: `https://linear.app/pinkgu/project/symphony-4c620c712be7`
- Team: `Pinkgu`
- Dispatch label: `codex-ready`
- Marker label: `symphony`

Use the same lifecycle states described in
`docs/agent-dashboard-linear-setup.md` and the canonical issue shape in
`docs/codex-agent-task-contract.md`. The workflow remains project-agnostic;
project specificity lives in the Linear project, issue content, repository URL,
and workspace root configured in `workflow-manifest.yml`.

## Bootstrap

Regenerate and check the workflow output after changing `workflow-manifest.yml`:

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
mise exec -- mix workflow.bootstrap --manifest ../workflow-manifest.yml
mise exec -- mix workflow.bootstrap --manifest ../workflow-manifest.yml --check
```

## Run

Start Symphony against the generated dogfood workflow:

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
export LINEAR_API_KEY=...
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  /Users/bjornjee/Code/bjornjee/symphony/workflows/symphony/workflow.md
```

Only add `codex-ready` when an issue is safe to dispatch. Use `Todo` for queued
agent work, `Human Review` for PRs/questions/decomposition, `Rework` for review
feedback, and `Merging` only after human approval.

For deterministic plugin routing, put the workflow directive in the issue's
`Notes For Agent`, for example `Use agent-dashboard:chore`. Symphony turns that
into the actual `$agent-dashboard:chore` invocation before Codex sees the task.

## Lifecycle Label Cleanup

Symphony owns Linear workflow-label cleanup in deterministic orchestration code,
not in agent prompt text. Configure cleanup under `tracker.cleanup_callbacks`
when a lifecycle transition makes dispatch or review labels stale.

Supported transition keys:

- `completed`: an agent process exits normally.
- `blocked`: an agent process stops because Codex needs human input or approval.
- `terminal`: Linear shows the issue in a configured terminal state.
- `inactive`: Linear shows the issue outside the configured active states or no
  longer routed to this worker.

Example:

```yaml
tracker:
  kind: "linear"
  required_labels: ["codex-ready"]
  cleanup_callbacks:
    completed:
      remove_labels: ["codex-ready", "codex-blocked", "codex-decompose"]
    blocked:
      remove_labels: ["codex-ready"]
    inactive:
      remove_labels: ["codex-ready"]
    terminal:
      remove_labels: ["codex-ready", "codex-review", "codex-blocked", "codex-decompose"]
```

Cleanup is idempotent: configured labels that are not attached to the current
issue are skipped. Linear cleanup uses the current issue id and that issue's
attached label ids; Symphony does not delete label definitions or look up labels
globally by name. If Linear rejects a cleanup mutation or an attached label id is
missing, Symphony records callback failure evidence and does not treat the
transition as a silent success.

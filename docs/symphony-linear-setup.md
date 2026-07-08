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
and workspace root configured in `WORKFLOWS.yml`.

## Bootstrap

Regenerate and check the workflow output after changing `WORKFLOWS.yml`:

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
mise exec -- mix workflow.bootstrap --manifest ../WORKFLOWS.yml
mise exec -- mix workflow.bootstrap --manifest ../WORKFLOWS.yml --check
```

## Run

Start Symphony against the generated dogfood workflow:

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
export LINEAR_API_KEY=...
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  /Users/bjornjee/Code/bjornjee/symphony/workflows/symphony/WORKFLOW.md
```

Only add `codex-ready` when an issue is safe to dispatch. Use `Todo` for queued
agent work, `Human Review` for PRs/questions/decomposition, `Rework` for review
feedback, and `Merging` only after human approval.

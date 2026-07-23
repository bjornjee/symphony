# Symphony Linear Setup

This project dogfoods Symphony against `bjornjee/symphony`.

Linear project:

- Name: `Symphony`
- URL: `https://linear.app/pinkgu/project/symphony-4c620c712be7`
- Team: `Pinkgu`
- Dispatch label: `codex-ready`
- Marker label: `symphony`

Use the canonical issue shape and native workflow routing described in
`docs/codex-agent-task-contract.md`. The workflow remains project-agnostic;
project specificity lives in the Linear project, issue content, repository URL,
and workspace root configured in `workflow-manifest.yml`.

## Prerequisites

Install the Elixir dependencies as described in `elixir/README.md`, then create
an untracked repo-root `.env` containing `LINEAR_API_KEY`. The default macOS
setup also requires the CA bundle at `/etc/ssl/cert.pem`.

## Bootstrap

From the repository root, regenerate and check the workflow output after
changing `workflow-manifest.yml`:

```bash
make symphony-workflow
make symphony-workflow-check
```

## Run

Start Symphony in the foreground against the generated dogfood workflow:

```bash
make symphony-run
```

The dashboard is available at `http://127.0.0.1:4000`. Stop the runner with
Ctrl-C. Override the port or CA bundle without editing the Makefile:

```bash
make symphony-run PORT=4001 CA_BUNDLE=/path/to/cert.pem
```

The target loads `.env` without printing its contents and passes the CA bundle
to Erlang through `ERL_AFLAGS`. If startup still reports a CA trust-store
failure, this is the core expanded launch command for troubleshooting:

```bash
(
  unset LINEAR_API_KEY
  set -a
  . ./.env
  set +a
  cd elixir
  ERL_AFLAGS="${ERL_AFLAGS:+${ERL_AFLAGS} }-eval 'public_key:cacerts_load(\"/etc/ssl/cert.pem\").'" \
    exec mise exec -- ./bin/symphony \
      --i-understand-that-this-will-be-running-without-the-usual-guardrails \
      --port 4000 \
      ../workflows/symphony/workflow.md
)
```

Only add `codex-ready` when an issue is safe to dispatch. Use `Todo` for queued
agent work, `Human Review` for PRs/questions/decomposition, `Rework` for review
feedback, and `Merging` only after human approval.

For the bounded pilot preflight, observable artifacts, diagnosis, retry, and
rollback procedure, follow the
[PIN-18 operational pilot runbook](pin-18-operational-pilot-runbook.md).

For deterministic routing, put an exact workflow directive in the issue's
`Notes For Agent`, for example `Workflow: chore`. Symphony selects and hashes
its built-in profile before any workspace execution; no runtime plugin is required.

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

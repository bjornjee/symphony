# PIN-18 Operational Pilot Runbook

This runbook is the operator contract for a bounded Symphony pilot. It permits
only two live paths:

1. the `make pilot` wrapper around the gated, disposable `live_e2e` target; or
2. the generated `workflows/symphony/WORKFLOW.md` against one prepared Symphony
   project issue.

Do not point the pilot at another workflow, broaden its labels/project, or make
ad hoc Linear mutations from a shell. The configured workflow runs Codex with
`danger-full-access`; read it before acknowledging the startup warning.

## Required names

Provision values out of band. Do not put them in this runbook, logs, audit
events, screenshots, or the evidence packet.

- Required environment: `LINEAR_API_KEY`.
- Required disposable-pilot environment: `SYMPHONY_LIVE_PULL_REQUEST_URL`.
- Optional evidence output: `SYMPHONY_LIVE_EVIDENCE_PATH`.
- Required local authentication: Codex authentication and GitHub CLI
  authentication.
- Optional live-test environment: `SYMPHONY_LIVE_LINEAR_TEAM_KEY`.
- Workflow controls already defined in `WORKFLOWS.yml`:
  `tracker.project_slug`, `tracker.required_labels`, `tracker.claim_state`,
  `tracker.handoff_state`, `tracker.active_states`,
  `tracker.terminal_states`, `workspace.root`,
  `polling.interval_ms`, `agent.max_concurrent_agents`, `agent.max_turns`,
  `hooks.after_create`, `codex.command`, `codex.approval_policy`,
  `codex.thread_sandbox`, and `codex.turn_sandbox_policy`.

## Bootstrap and preflight

Bootstrap is required after a fresh checkout, dependency/runtime update, or a
change to `WORKFLOWS.yml`. Run exactly:

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- mix workflow.bootstrap --manifest ../WORKFLOWS.yml
mise exec -- mix workflow.bootstrap --manifest ../WORKFLOWS.yml --check
```

Before either live path, run this non-mutating preflight:

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
git status --short --untracked-files=no
test -z "$(git ls-files --others --exclude-standard | grep -v -x '.env')"
git rev-parse HEAD
test -f "${HOME}/.codex/auth.json"
command -v codex
codex --version
command -v gh
gh auth status
command -v make
command -v curl
command -v jq
test -x ./bin/symphony
test -f ../workflows/symphony/WORKFLOW.md
mise exec -- mix workflow.bootstrap --manifest ../WORKFLOWS.yml --check
(
  source /Users/bjornjee/Code/bjornjee/symphony/.env
  export LINEAR_API_KEY
  test -n "${LINEAR_API_KEY:-}"
)
```

Stop if the tracked-file status prints anything, if any untracked path other
than the canonical root `.env` exists, or if the recorded revision is not the
reviewed pilot revision. The explicit `.env` exception permits presence only;
it does not permit printing, copying, staging, or committing that file.

For the configured-workflow path, prepare exactly one issue in the documented
Symphony Linear project. It must conform to `Codex Agent Task v1`, be in `Todo`,
and have `codex-ready`. Confirm no other issue in the project has both an active
state and `codex-ready`. That bounds the pilot to one issue; the workflow also
sets `agent.max_concurrent_agents` to `1`.

For the disposable path, also confirm the configured Linear team exists and
that `SYMPHONY_LIVE_PULL_REQUEST_URL` names the reviewed Symphony PR to verify.
If `SYMPHONY_LIVE_EVIDENCE_PATH` is set, it must name the output JSON file, not
a directory. Never copy, print, or commit `.env`; source the canonical file only
inside the command subshell so `LINEAR_API_KEY` is discarded when the run ends.

## Run one pilot

### Disposable live end-to-end

`make pilot` sets the existing `SYMPHONY_RUN_LIVE_E2E=1` gate and selects only
the `pin18_pilot` disposable local Linear/Codex scenario. It proves that a second
agent attempt reuses the pinned plan and thread, writes evidence for the exact
successful result-file verification command, validates the supplied real PR,
publishes one read-verified handoff, and reaches the configured state. It marks
and read-verifies the disposable Linear project as completed when successful;
on failure it attempts best-effort project finalization and preserves the local
workspace path printed in the log for diagnosis.

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
(
  source /Users/bjornjee/Code/bjornjee/symphony/.env
  export LINEAR_API_KEY
  test -n "${LINEAR_API_KEY:-}"
  test -n "${SYMPHONY_LIVE_PULL_REQUEST_URL:-}"
  export SYMPHONY_LIVE_PULL_REQUEST_URL
  export SYMPHONY_LIVE_EVIDENCE_PATH
  mise exec -- make pilot
)
```

Do not invoke the test file with a hand-written enable flag or use the broader
`make e2e` suite as this pilot; use the bounded repository target.

### Configured Symphony workflow

After the single-issue preflight, start the generated workflow exactly:

```bash
cd /Users/bjornjee/Code/bjornjee/symphony/elixir
(
  source /Users/bjornjee/Code/bjornjee/symphony/.env
  export LINEAR_API_KEY
  test -n "${LINEAR_API_KEY:-}"
  mise exec -- ./bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --port 4000 \
    /Users/bjornjee/Code/bjornjee/symphony/workflows/symphony/WORKFLOW.md
)
```

Leave the process attached for the pilot. Do not start a second instance against
the same project. In steady state Symphony polls every 30 seconds, claims the
issue as `In Progress`, clones the configured repository into
`~/Code/bjornjee/worktrees/symphony/<issue-identifier>`, pins the approved plan
and Codex thread, runs bounded continuation turns, validates completion
evidence, read-verifies one deterministic handoff comment, then moves the issue
to `Human Review`.

Expected local artifacts are:

- `elixir/log/symphony.log` and its bounded rotating files;
- `.symphony/execution-manifest.json` and `.symphony/codex-thread.json` in the
  issue workspace;
- `.symphony/run-audit.jsonl` and `.symphony/run-audit.md` in the workspace;
- `.symphony/completion-evidence.json` when the agent reaches handoff; and
- the branch/commit/PR named by validated evidence, followed by one
  `## Agent Handoff` Linear comment and the configured handoff state.

Terminal issues are cleaned up, so capture the bounded audit fields before
intentionally moving a configured-workflow pilot issue to a terminal state. For
the disposable target, set `SYMPHONY_LIVE_EVIDENCE_PATH` outside its temporary
workspace so the packet described below survives cleanup.

## Observe and diagnose a stuck run

With `--port 4000`, use the runtime API first, then the bounded tail of the log:

```bash
curl --fail --silent --show-error http://127.0.0.1:4000/api/v1/state | jq .
curl --fail --silent --show-error http://127.0.0.1:4000/api/v1/PIN-18 | jq .
tail -n 200 /Users/bjornjee/Code/bjornjee/symphony/elixir/log/symphony.log
```

Replace `PIN-18` only with the prepared pilot issue identifier. Follow the
returned `audit_path` and `audit_events_path`; inspect the last bounded slice:

```bash
tail -n 80 /Users/bjornjee/Code/bjornjee/worktrees/symphony/PIN-18/.symphony/run-audit.jsonl
tail -n 120 /Users/bjornjee/Code/bjornjee/worktrees/symphony/PIN-18/.symphony/run-audit.md
```

Interpret common states as follows:

- `running`: inspect the latest phase and session/thread correlation; do not
  dispatch a duplicate.
- `retrying`: note `attempt`, `due_at`, and the concise error, then let the
  scheduled retry resume the pinned workspace and thread. Do not copy free-form
  error text into metric labels or the evidence packet.
- `blocked`: perform the requested human action or leave the issue stopped. The
  blocked scheduler map is in memory, but the pinned thread is durable.
- no runtime entry: verify project, active state, required label, task-contract
  fields, and the last workflow reload error.
- handoff evidence pending/rejected: inspect the completion artifact and
  referenced engine-observed proof event IDs. Do not fabricate proof or move the
  issue manually to the handoff state.
- ambiguous handoff creation/readback or state transition: do not post another
  handoff or force the state. Preserve the workspace and retry the same issue so
  deterministic readback can converge or fail closed.

## Safe retry, recovery, and rollback

1. Stop dispatch first: remove `codex-ready` from the pilot issue in Linear.
2. Observe until Symphony stops the now-unroutable worker on its next refresh.
   If immediate containment is required, stop the attached process with
   `Ctrl-C`.
3. Preserve the issue workspace and all `.symphony` files. They bind retries to
   the approved plan and thread and retain bounded diagnostic and handoff
   evidence. After a process restart, Symphony must observe proof again; do not
   treat an old command event as proof for the new attempt.
4. Correct only the missing dependency or explicit human decision. Re-run the
   bootstrap `--check`, restore `codex-ready` only for the same issue, and start
   the same generated workflow once.
5. Verify the resumed `thread_id` and `plan_digest` before accepting new work.

Never delete the workspace to clear a retry, edit pinned identity files, create
a replacement handoff comment, or force the issue into `Human Review`. A title
or description change after pinning is a new plan revision: Symphony stops
rather than silently adopting it. This pilot has no in-place reapproval: stop
dispatch and return the changed plan to the normal issue planning flow instead
of modifying the manifest.

Rollback is operational: remove the dispatch label, stop Symphony, retain the
workspace for diagnosis, and revert the source revision through the normal Git
workflow. Workflow generation is one-way from `WORKFLOWS.yml`; do not hand-edit
the generated `WORKFLOW.md` as a rollback.

## Bootstrap versus steady state and missing dependencies

- Bootstrap installs dependencies, builds the escript, and generates checked
  workflow outputs. Failure blocks startup; it must not be bypassed.
- Steady state reads one generated workflow, polls one configured project, and
  creates work only for issues satisfying state, label, and task-contract gates.
- A missing workflow file or invalid startup YAML prevents Symphony from
  booting. A bad later reload keeps the last known-good workflow and logs the
  error.
- A missing canonical `.env` or `LINEAR_API_KEY` fails preflight; do not copy a
  secret file into the checkout or issue workspace.
- A missing `SYMPHONY_LIVE_PULL_REQUEST_URL` makes `make pilot` exit before the
  live test. An unset `SYMPHONY_LIVE_EVIDENCE_PATH` permits the test but writes
  no summary packet.
- Missing Linear authentication prevents tracker work. A missing Codex binary,
  Codex authentication, repository access, or workspace hook dependency fails
  the attempt and enters bounded retry behavior; it does not justify a
  replacement workspace or thread. Use `blocked` only when Codex explicitly
  reports that operator input, approval, or elicitation is required.
- Missing `gh` authentication prevents PR-backed completion evidence from being
  trusted. Leave the issue active until verification succeeds.
- `make pilot` is intentionally local-worker only. SSH/Docker coverage remains
  in the broader `make e2e` suite and is not part of this bounded pilot.

## Structured event and metric contract

`.symphony/run-audit.jsonl` is the machine-readable source. Every audit event
has the engine-owned envelope `timestamp`, `event`, `issue_id`, and
`issue_identifier`. Lifecycle attributes use `phase` and `status` where the
event has a stateful phase. Bounded phases are `run`, `workspace`,
`codex_app_server`, `codex_session`, `codex_goal`, `codex_turn`, `command`, and
`handoff`.
Handoff events use only allowlisted scalar fields:

- correlation: `thread_id`, `plan_digest`, and `artifact_digest`;
- deterministic comment identity: `comment_id` and `marker_key`;
- evidence and state: `evidence_result`, `transition_target`,
  `transition_result`, `issue_state`, and `result`;
- retry and ambiguity decisions: boolean `retry` and `ambiguous`.

The bounded values are
`evidence_result=accepted|pending|rejected|publish_failed|validated|published`,
`transition_result=updated|reused|ambiguous|reconciled|read_failed|mismatch`,
and `result=started|pending|completed|failed` where those fields apply. Failure
is represented by the specific bounded event name and categorized result, not
by attaching an external response body.

Derive low-cardinality counts and durations only from bounded fields: `event`,
`phase`, `status`, `evidence_result`, `transition_result`, `result`, `retry`, and
`ambiguous`. For example, count handoff results and ambiguity/retry decisions,
or measure elapsed time between phase events. Never use issue IDs, issue
identifiers, thread/session IDs, plan/artifact digests, comment IDs, marker
keys, state names, URLs, commands, error text, or file paths as metric labels.

The JSONL and Markdown audit may identify a run, but they must not contain raw
model reasoning, secrets, full prompts, environment dumps, command output
streams, tracker payloads, or other unbounded payloads. Keep only bounded command
summaries, exit status, durations, proof IDs, and categorized errors.

## Non-secret pilot evidence packet

When `SYMPHONY_LIVE_EVIDENCE_PATH` is set, `make pilot` writes one bounded JSON
object after the handoff is read back. It is an operator summary, not a
substitute for engine evidence. The schema is:

```json
{
  "schema_version": 1,
  "started_at": "RFC3339",
  "completed_at": "RFC3339",
  "command": "mise exec -- make pilot",
  "linear_issue": {
    "id": "id",
    "identifier": "key",
    "url": "https-url"
  },
  "linear_project": {"id": "id", "url": "https-url"},
  "pull_request_url": "https-url",
  "thread_id": "id",
  "plan_digest": "sha256",
  "manifest_sha256": "sha256",
  "manifest_reused": true,
  "attempts": [
    {"attempt": 1, "thread_id": "id", "goal_status": "active", "evidence_result": "pending"},
    {"attempt": 2, "thread_id": "id", "goal_status": "complete", "evidence_result": "validated"}
  ],
  "criteria": [{"criterion_id": "id", "outcome": "passed"}],
  "evidence_result": "accepted",
  "handoff_comment_id": "id",
  "final_state": "state"
}
```

The criteria array is bounded by the approved task contract. The file contains
no token, credential, raw log, prompt, reasoning, arbitrary notes, or request/
response body. IDs, digests, URLs, and state are evidence dimensions only; they
are not metric labels. If the run fails before evidence is written, retain the
bounded log/audit tail and record the failure separately without inventing a
successful packet.

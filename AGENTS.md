# Symphony Agent Guide

This file applies to the whole repository. The more specific rules in
`elixir/AGENTS.md` also apply to work under `elixir/`.

## Start Symphony

Use the managed Make targets from any checkout or linked git worktree:

```bash
make symphony-up
make symphony-status
```

`symphony-up` finds `.env` in the current worktree or the primary checkout,
checks `LINEAR_API_KEY`, the CA bundle, workflow, executable, and required
commands, starts one background process, and waits for `/api/v1/state`.

Do not manually expand the launch command unless troubleshooting the service
script itself. Use `make symphony-run` only when foreground output and Ctrl-C
shutdown are intentionally required.

## Operate Symphony

```bash
make symphony-status
make symphony-logs
make symphony-restart
make symphony-down
```

- `symphony-up` is idempotent and reports an existing instance.
- `symphony-status` reports running, retrying, and blocked agent counts.
- `symphony-logs` follows Symphony's rotating service log. Use
  `FOLLOW=0 make symphony-logs` for a bounded snapshot.
- `symphony-down` stops only the process recorded by the managed launcher. It
  refuses to kill a foreground or otherwise external instance.

Override the normal configuration without editing tracked files:

```bash
make symphony-up PORT=4001 CA_BUNDLE=/path/to/cert.pem
SYMPHONY_ENV_FILE=/path/to/.env make symphony-up
```

## Safety

- Never print, copy, stage, or commit `.env`.
- Run `make symphony-status` before starting or stopping the service.
- Never kill Symphony with a broad process-name match.
- Preserve a dirty issue workspace and diagnose it; do not delete it to make a
  dispatch retry pass.
- Regenerate and check the dogfood workflow after manifest changes:

```bash
make symphony-workflow
make symphony-workflow-check
```

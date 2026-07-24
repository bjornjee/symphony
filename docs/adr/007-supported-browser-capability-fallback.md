# ADR 007: Supported browser capability fallback

## Context
Codex Browser backends are bound to their originating Desktop turn, while Symphony launches a separate app-server session. The supported app-server protocol cannot attach or delegate that backend.

## Decision
At app-server startup, Symphony distinguishes global configuration from runtime usability for Browser, Computer Use, and Playwright. A bound Codex Browser backend is preferred; otherwise a responsive inherited Playwright MCP is selected for deterministic automated rendering, inspection, screenshots, and behavior checks.

When an approved local proof command uses Playwright Test, Symphony resolves its exact stable version from the nearest workspace `package-lock.json`, selects only a matching Playwright runtime from a bounded npm execution cache, and starts that trusted runtime as a one-client loopback server. The server receives a minimal secret-free environment. Only its ephemeral endpoint is added to the sandboxed `command/exec` environment, and that endpoint is redacted from command output and receipts. Repository-controlled Playwright code remains inside `command/exec`; missing, mismatched, remote-worker, or failed server runtimes fail with actionable diagnostics.

Capability selection provenance and actual proof execution provenance are recorded separately in immutable proof receipts and audit events. Neither contains browser endpoints or session identifiers.

## Consequences
Browser plugin enablement alone never implies a usable backend. Computer Use inheritance is verified independently. Existing approved Playwright Test commands keep their full interaction and visual assertions while browser launch occurs through the supported Playwright connection environment. Visual workflows fail accurately when neither backend responds or no exact cached Playwright runtime is available. Browser delegation remains an upstream Codex app-server dependency rather than a local transport workaround.

## Rollback
Revert the proof-server bridge and additive receipt fields; existing agent execution and observability schemas accept their absence. No data migration is required.
